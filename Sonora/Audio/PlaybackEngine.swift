//
//  PlaybackEngine.swift
//  Sonora
//
//  The AVAudioEngine graph plus a sample-accurate scheduler.
//
//  Two player nodes exist so we can crossfade; when crossfade is off we use
//  a single node and chain the next file directly behind the current one,
//  which is what makes playback truly gapless (no engine stop, no re-arm).
//

import Foundation
import AVFoundation
import Combine
import QuartzCore
import Accelerate

/// Everything the engine needs to play one item. The library layer resolves
/// security-scoped URLs and replay-gain before handing this over.
struct PlayableItem: Equatable {
    let trackID: UUID
    let url: URL
    /// Offset into the file (non-zero for cue-sheet tracks or resume).
    var startTime: TimeInterval = 0
    /// End offset; `nil` means play to the end of the file.
    var endTime: TimeInterval?
    /// Linear gain applied on this item's mixer (replay gain).
    var gainDB: Float = 0
    var duration: TimeInterval = 0
}

private struct Segment {
    let trackID: UUID
    let startFrame: AVAudioFramePosition   // in the player node's timeline
    let frameCount: AVAudioFramePosition
    let fileStartFrame: AVAudioFramePosition
    let sampleRate: Double
    var endFrame: AVAudioFramePosition { startFrame + frameCount }
}

/// Seconds to frames without trapping.
///
/// `AVAudioFramePosition(x)` is a hard crash when `x` is NaN, infinite or
/// outside Int64, and all three can come out of a bad tag, a malformed cue
/// sheet or a zero sample rate. Negative results clamp to 0 and the ceiling
/// (about 290 days at 44.1 kHz) is far beyond any real file.
/// Runs `body`, turning an Objective-C exception from AVAudioEngine into a
/// logged `false` instead of a crash. See SonoraObjC.h.
@discardableResult
func sonoraCatch(_ label: String, _ body: () -> Void) -> Bool {
    if let reason = SonoraObjC.catchException(body) {
        print("[Engine] \(label) raised \(reason)")
        return false
    }
    return true
}

func sonoraFramePosition(seconds: Double, sampleRate: Double) -> AVAudioFramePosition {
    let value = seconds * sampleRate
    let ceiling: Double = 1_099_511_627_776   // 2^40
    if value.isNaN { return 0 }
    return AVAudioFramePosition(min(max(value, 0), ceiling))
}

final class PlaybackEngine {

    // MARK: Nodes

    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let gainA = AVAudioMixerNode()
    private let gainB = AVAudioMixerNode()
    private let sourceMixer = AVAudioMixerNode()
    let chain: DSPChain

    private let settings: AppSettings
    private let session = AudioSessionManager.shared

    // MARK: State

    /// Which of the two player nodes is currently the primary one.
    private var usingA = true
    private var player: AVAudioPlayerNode { usingA ? playerA : playerB }
    private var idlePlayer: AVAudioPlayerNode { usingA ? playerB : playerA }
    private var activeGain: AVAudioMixerNode { usingA ? gainA : gainB }
    private var idleGain: AVAudioMixerNode { usingA ? gainB : gainA }

    private var segments: [Segment] = []
    private var nextScheduleFrame: AVAudioFramePosition = 0
    private var openFiles: [UUID: AVAudioFile] = [:]
    private var currentFormat: AVAudioFormat?
    private var chainFormat: AVAudioFormat
    private var pendingCrossfadeItem: PlayableItem?

    private var currentItem: PlayableItem?
    private var chainedItem: PlayableItem?

    private(set) var isPlaying = false
    private var wasPlayingBeforeInterruption = false

    // Fades
    private var fade: (from: Float, to: Float, start: CFTimeInterval, duration: Double, node: AVAudioMixerNode, completion: (() -> Void)?)?
    private var crossfadeRamp: (start: CFTimeInterval, duration: Double)?

    private var ticker: Timer?
    private var tickerInterval: TimeInterval?

    /// Set by the controller. In the background nobody sees the playhead,
    /// so the ticker drops to 1 Hz housekeeping.
    var isForeground = true { didSet { if oldValue != isForeground { updateTicker() } } }

    /// Last good position reading. A paused (idle) engine reports no render
    /// time, so this is what `currentTime` falls back to.
    private var frozenTime: TimeInterval?
    /// Host time at which `frozenTime` was last captured from a live reading.
    private var frozenAt: CFTimeInterval = 0
    private var idleWorkItem: DispatchWorkItem?
    private(set) var isMeterTapInstalled = false

    private var configObserver: NSObjectProtocol?
    /// Guards against a configuration-change notification arriving while we are
    /// part-way through rebuilding the graph for the last one.
    private var isRebuilding = false
    /// The hardware changed while we were not playing. Rebuilding right then
    /// would mean grabbing the audio session from whichever app is playing
    /// now, so the rebuild waits for our next play().
    private var graphNeedsRebuild = false

    /// Set the moment a new schedule is installed, cleared once the node
    /// reports a sample time that actually falls inside it.
    ///
    /// `AVAudioPlayerNode.lastRenderTime` keeps reporting the *previous*
    /// schedule's frame for a render cycle or two after stop()/scheduleSegment()
    /// /play(). That stale frame sits past the freshly scheduled segment, so
    /// `currentSegment()` fell through to its `segments.last` fallback and
    /// handed back the chained next track — and `tick()` read that as a gapless
    /// advance. The visible result was that scrubbing the seek bar skipped to
    /// the next song.
    private var awaitingFirstRender = false

    /// Every scheduled segment gets an id, and only ids still in this set are
    /// allowed to report completion.
    ///
    /// `AVAudioPlayerNode.scheduleSegment` calls its completion handler when the
    /// segment finishes **or when the node is stopped**. Seeking stops the node
    /// and reschedules, so the abandoned schedule's handler fired a moment
    /// later, hopped to the main queue, and by then `segments.last` was the
    /// freshly seeked segment - same track id - so `segmentFinished` read it as
    /// "everything scheduled has played" and advanced to the next song. Tapping
    /// the seek bar therefore changed track instead of moving the playhead.
    private var liveScheduleIDs: Set<Int> = []
    private var nextScheduleID = 0
    /// Id of the segment on the incoming crossfade player, which has to survive
    /// the outgoing player being stopped.
    private var crossfadeScheduleID: Int?

    /// Registers a new schedule and returns its id.
    private func newScheduleID() -> Int {
        nextScheduleID += 1
        liveScheduleIDs.insert(nextScheduleID)
        return nextScheduleID
    }

    // MARK: Callbacks (set by PlaybackController)

    /// The engine crossed into a different scheduled segment.
    var onAdvanced: ((UUID) -> Void)?
    /// Everything scheduled has finished playing.
    var onFinished: (() -> Void)?
    /// Asked when the engine wants a track to chain or crossfade into.
    var provideNextItem: (() -> PlayableItem?)?
    /// Position updates on the main queue: 4 Hz in the foreground, 1 Hz in
    /// the background, 30 Hz only while a fade or crossfade is running.
    var onTick: ((TimeInterval, TimeInterval) -> Void)?
    /// A hard failure that the UI should surface.
    var onError: ((String) -> Void)?
    /// The file asked for could not be opened. The Bool says whether it was
    /// meant to start playing, so the controller can move on to the next song.
    var onUnplayable: ((AudioFileDoctor.Failure, Bool) -> Void)?
    /// Why the most recent `openFile` call failed.
    private var lastOpenFailure: AudioFileDoctor.Failure?
    /// Play state changed (including engine-initiated pauses and resumes).
    var onPlayStateChanged: ((Bool) -> Void)?

    // MARK: - Init

    init(settings: AppSettings) {
        self.settings = settings
        self.chain = DSPChain(settings: settings)
        let sr = AVAudioSession.sharedInstance().sampleRate
        self.chainFormat = AVAudioFormat(standardFormatWithSampleRate: sr > 0 ? sr : 48_000,
                                         channels: 2)!
        attachNodes()
        buildGraph()
        hookSession()
        hookEngineConfiguration()
        // No ticker and no running engine until something actually plays.
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        ticker?.invalidate()
    }

    /// AVAudioEngine tears its own connections down when the hardware format
    /// changes underneath it - a new route, or the sample-rate switch we ask
    /// for when a file with a different rate loads - and says so through this
    /// notification. Nothing was listening, so after such a change the graph
    /// was left connected at the old rate: every sample got resampled up to it
    /// and then back down again on the way out, which is two conversions where
    /// there should be none.
    private func hookEngineConfiguration() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main) { [weak self] _ in
                self?.rebuildForCurrentRoute(force: true)
            }
    }

    private func attachNodes() {
        for node in [playerA, playerB, gainA, gainB, sourceMixer] as [AVAudioNode] {
            engine.attach(node)
        }
        for node in chain.orderedNodes { engine.attach(node) }
    }

    private func buildGraph() {
        let fmt = chainFormat

        sonoraCatch("connect graph") {
            engine.connect(gainA, to: sourceMixer, format: fmt)
            engine.connect(gainB, to: sourceMixer, format: fmt)
        }

        // Player -> gain connections are (re)made per file format in `connectPlayer`.
        connectPlayer(playerA, to: gainA, format: currentFormat ?? fmt)
        connectPlayer(playerB, to: gainB, format: currentFormat ?? fmt)

        sonoraCatch("connect chain") {
            var previous: AVAudioNode = sourceMixer
            for node in chain.orderedNodes {
                engine.connect(previous, to: node, format: fmt)
                previous = node
            }
            engine.connect(previous, to: engine.mainMixerNode, format: fmt)
        }

        // Preparing against a route with no hardware format (mid route change,
        // during a call) can raise an Objective-C exception. `start()` prepares
        // on its own later, so skipping it here costs nothing.
        if outputRouteIsUsable { sonoraCatch("prepare") { engine.prepare() } }
    }

    /// Tears the graph down and rebuilds it at `format`.
    private func resetGraph(to format: AVAudioFormat) {
        stopEngineOnly()
        chainFormat = format
        for node in chain.orderedNodes { engine.disconnectNodeOutput(node) }
        engine.disconnectNodeOutput(sourceMixer)
        engine.disconnectNodeOutput(gainA)
        engine.disconnectNodeOutput(gainB)
        buildGraph()
        chain.applyAll()
    }

    /// False while the hardware reports no usable output format. Starting or
    /// preparing the engine then raises an exception Swift cannot catch.
    private var outputRouteIsUsable: Bool {
        let hw = engine.outputNode.outputFormat(forBus: 0)
        return hw.sampleRate > 0 && hw.channelCount > 0
    }

    /// Formats a player node can safely be connected with. Connecting a 0 Hz /
    /// 0 channel format, or a multichannel one with no channel layout, raises
    /// an Objective-C exception inside `AVAudioEngine.connect`.
    private static func isConnectable(_ format: AVAudioFormat) -> Bool {
        guard format.sampleRate > 0, format.sampleRate.isFinite,
              format.channelCount > 0 else { return false }
        if format.channelCount > 2 && format.channelLayout == nil { return false }
        return true
    }

    @discardableResult
    private func connectPlayer(_ node: AVAudioPlayerNode,
                               to mixer: AVAudioMixerNode,
                               format: AVAudioFormat) -> Bool {
        sonoraCatch("connect player") {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: mixer, format: format)
        }
    }

    private func hookSession() {
        session.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            self.wasPlayingBeforeInterruption = self.isPlaying
            self.pause(fade: false)
        }
        session.onInterruptionEnded = { [weak self] shouldResume in
            guard let self else { return }
            if shouldResume && self.wasPlayingBeforeInterruption {
                self.play()
            }
        }
        session.onOldDeviceUnavailable = { [weak self] in
            guard let self, self.settings.pauseOnDisconnect else { return }
            self.pause(fade: true)
        }
        session.onNewDeviceAvailable = { [weak self] in
            guard let self, self.settings.resumeOnHeadphones, !self.isPlaying,
                  self.currentItem != nil else { return }
            self.play()
        }
        session.onRouteConfigurationChanged = { [weak self] in
            self?.rebuildForCurrentRoute()
        }
    }

    // MARK: - Graph rebuild

    private func rebuildForCurrentRoute(force: Bool = false) {
        guard !isRebuilding else { return }
        let sr = AVAudioSession.sharedInstance().sampleRate

        // Not playing: another app may own the speaker right now (it is often
        // that app's own sample-rate switch that sent us here). Rebuilding
        // would reload the song, re-activate our session and cut that app
        // off - the "Sonora stops my other app" bug. Remember and do it on
        // our next play() instead.
        guard isPlaying else {
            if force || (sr > 0 && abs(sr - chainFormat.sampleRate) > 1) {
                graphNeedsRebuild = true
            }
            return
        }

        guard sr > 0 else { return }
        // A configuration change has already invalidated the connections, so
        // the graph has to be rebuilt whether or not the rate moved.
        guard force || abs(sr - chainFormat.sampleRate) > 1 else { return }
        guard let rebuilt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }

        isRebuilding = true
        defer { isRebuilding = false }

        let resumePosition = currentTime
        let wasPlaying = isPlaying
        let item = currentItem

        graphNeedsRebuild = false
        resetGraph(to: rebuilt)

        if var item {
            item.startTime = resumePosition
            load(item: item, autoplay: wasPlaying)
        }
    }

    private func ensureEngineRunning() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
        guard !engine.isRunning else { return }
        guard outputRouteIsUsable else {
            onError?("No audio output is available right now.")
            return
        }
        var startError: Error?
        let survived = sonoraCatch("start") {
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if !survived {
            onError?("The audio output is busy. Try again in a moment.")
        } else if let startError {
            onError?("Audio engine failed to start: \(startError.localizedDescription)")
        }
    }

    // MARK: - Idle power management

    /// A running AVAudioEngine keeps the audio hardware and render thread
    /// awake even when every player is paused. Apple's guidance is to pause
    /// the engine whenever nothing needs to be heard, so we do that a few
    /// seconds after playback stops (the delay avoids churn on quick toggles).
    private func scheduleEngineIdle() {
        idleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.pauseEngineIfIdle() }
        idleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func pauseEngineIfIdle() {
        idleWorkItem = nil
        guard !isPlaying, engine.isRunning else { return }
        // Still ramping volume: try again once the ramp is done.
        if fade != nil || crossfadeRamp != nil {
            scheduleEngineIdle()
            return
        }
        frozenTime = currentTime
        engine.pause()
        updateTicker()
        // Hand the speaker back. Other apps (Spotify, YouTube, a podcast)
        // that we interrupted can then carry on, the way they do after
        // Apple Music pauses. play() takes it again.
        session.deactivate()
    }

    private func stopEngineOnly() {
        playerA.stop()
        playerB.stop()
        engine.stop()
    }

    // MARK: - Loading

    /// Loads and (optionally) starts an item, replacing anything scheduled.
    func load(item: PlayableItem, autoplay: Bool) {
        // Only claim the audio session when we are about to make sound.
        // Loading quietly (restoring the last song at launch, a seek while
        // paused) used to activate it too, which stopped whatever other app
        // was playing just because Sonora was opened.
        if autoplay { session.activate() }

        guard let file = openFile(for: item) else {
            reportUnplayable(item, wantedToPlay: autoplay)
            return
        }

        // Try to run the hardware at the file's native rate. Under battery
        // saver we cap at 48 kHz: hi-res rates double or quadruple the work
        // every effect in the chain does, for no audible gain on most outputs.
        let fileRate = file.processingFormat.sampleRate
        // Never ask the hardware to run below 44.1 kHz. Low-rate files (many
        // older or voice-quality MP3s are 22 or 32 kHz) are resampled up by
        // the mixer instead; dragging the whole effect chain down to their
        // rate puts the upper EQ bands above what that rate can carry.
        let wantedRate = max(44_100, fileRate)
        let targetRate = settings.batterySaverActive ? min(wantedRate, 48_000) : wantedRate
        let achieved = session.preferSampleRate(targetRate)
        // AVAudioSession.sampleRate reports 0 when the session has no active
        // route (during an interruption, or mid route change). Building an
        // AVAudioFormat at 0 Hz returns nil, so the force-unwrap below used to
        // crash. Keep the current format in that case and let the route-change
        // handler rebuild once a real rate exists.
        if achieved > 0, abs(achieved - chainFormat.sampleRate) > 1,
           let rebuilt = AVAudioFormat(standardFormatWithSampleRate: achieved, channels: 2) {
            resetGraph(to: rebuilt)
        }
        if autoplay { graphNeedsRebuild = false }

        playerA.stop()
        playerB.stop()
        usingA = true
        gainA.volume = 1
        gainB.volume = 0
        crossfadeRamp = nil
        pendingCrossfadeItem = nil
        chainedItem = nil
        segments.removeAll()
        // Anything the previous schedule still has in flight is meaningless now.
        liveScheduleIDs.removeAll()
        crossfadeScheduleID = nil
        nextScheduleFrame = 0
        awaitingFirstRender = true
        frozenTime = nil
        openFiles = [item.trackID: file]

        currentFormat = file.processingFormat
        let connected = connectPlayer(playerA, to: gainA, format: file.processingFormat)
        connectPlayer(playerB, to: gainB, format: file.processingFormat)
        guard connected else {
            // Without this the player was left unplugged and the song simply
            // sat there silent, with no message at all.
            let format = file.processingFormat
            lastOpenFailure = AudioFileDoctor.Failure(
                problem: .unreadable,
                message: "“\(item.url.lastPathComponent)” uses a sound format the player cannot handle (\(Int(format.sampleRate)) Hz, \(format.channelCount) channels).")
            reportUnplayable(item, wantedToPlay: autoplay)
            return
        }

        currentItem = item
        applyGain(item.gainDB, to: gainA, ramp: false)

        guard scheduleOnActivePlayer(item: item, file: file) else {
            // Nothing left to schedule (start at or past the end, or a cue
            // range that ends before it begins). Both players are stopped, so
            // stop claiming to play instead of running the ticker over silence.
            let wasPlaying = isPlaying
            isPlaying = false
            scheduleEngineIdle()
            updateTicker()
            onError?("Nothing to play in \(item.url.lastPathComponent)")
            if wasPlaying { onPlayStateChanged?(false) }
            return
        }

        if autoplay {
            play()
        } else {
            // Loading without playing (launch restore, seek while paused)
            // must not leave the engine rendering silence.
            isPlaying = false
            scheduleEngineIdle()
            updateTicker()
            // No ticker runs while paused, so publish the position and real
            // duration once here.
            onTick?(currentTime, currentDuration)
        }
        maybeChainNext()
    }

    private func openFile(for item: PlayableItem) -> AVAudioFile? {
        let scoped = item.url.startAccessingSecurityScopedResource()
        defer { if scoped { /* keep access for the life of the file object */ } }
        // The doctor opens the file normally when it can, and otherwise works
        // out what is wrong with it (wrong extension, junk before the audio,
        // still in iCloud...) and repairs what is repairable.
        switch AudioFileDoctor.open(item.url) {
        case .success(let file):
            lastOpenFailure = nil
            return file
        case .failure(let failure):
            lastOpenFailure = failure
            print("[Engine] open failed: \(failure.message)")
            return nil
        }
    }

    /// Stops whatever was playing and tells the controller why the new item
    /// could not start.
    private func reportUnplayable(_ item: PlayableItem, wantedToPlay: Bool) {
        let failure = lastOpenFailure ?? AudioFileDoctor.Failure(
            problem: .unreadable,
            message: "“\(item.url.lastPathComponent)” could not be opened.")
        // The screen now shows the new song; the old one must not keep playing.
        playerA.stop()
        playerB.stop()
        segments.removeAll()
        liveScheduleIDs.removeAll()
        crossfadeScheduleID = nil
        chainedItem = nil
        pendingCrossfadeItem = nil
        crossfadeRamp = nil
        currentItem = nil
        let wasPlaying = isPlaying
        isPlaying = false
        scheduleEngineIdle()
        updateTicker()
        if wasPlaying { onPlayStateChanged?(false) }

        if let onUnplayable {
            onUnplayable(failure, wantedToPlay)
        } else {
            onError?(failure.message)
        }
    }

    @discardableResult
    private func scheduleOnActivePlayer(item: PlayableItem, file: AVAudioFile) -> Bool {
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return false }
        let startFrame = sonoraFramePosition(seconds: item.startTime, sampleRate: sr)
        let endFrame: AVAudioFramePosition = {
            if let end = item.endTime { return min(file.length, sonoraFramePosition(seconds: end, sampleRate: sr)) }
            return file.length
        }()
        // startFrame >= length gives frames <= 0; a frame count over UInt32
        // would trap in the AVAudioFrameCount conversion below.
        let frames = min(endFrame - startFrame, AVAudioFramePosition(AVAudioFrameCount.max))
        guard startFrame < file.length, frames > 0 else { return false }

        let segment = Segment(trackID: item.trackID,
                              startFrame: nextScheduleFrame,
                              frameCount: frames,
                              fileStartFrame: startFrame,
                              sampleRate: sr)
        segments.append(segment)
        nextScheduleFrame += frames

        let node = player
        let scheduleID = newScheduleID()
        node.scheduleSegment(file,
                             startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(frames),
                             at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.liveScheduleIDs.remove(scheduleID) != nil else { return }
                self.segmentFinished(trackID: segment.trackID)
            }
        }
        return true
    }

    private func segmentFinished(trackID: UUID) {
        // If nothing else is queued behind this segment we are done.
        guard let last = segments.last else { return }
        if last.trackID == trackID && pendingCrossfadeItem == nil {
            onFinished?()
        }
    }

    // MARK: - Gapless chaining

    /// Asks the controller for the following track and, when the format
    /// matches, schedules it immediately behind the current one.
    func maybeChainNext() {
        guard settings.gaplessEnabled,
              !settings.crossfadeEnabled,
              chainedItem == nil,
              let format = currentFormat,
              let next = provideNextItem?() else { return }

        guard let file = openFile(for: next) else { return }
        let nf = file.processingFormat
        guard nf.sampleRate == format.sampleRate,
              nf.channelCount == format.channelCount else {
            // Different format: it will be loaded the normal way on advance.
            return
        }
        openFiles[next.trackID] = file
        chainedItem = next
        scheduleOnActivePlayer(item: next, file: file)
    }

    /// Drops a previously chained item (queue changed under us).
    func invalidateChain() {
        guard chainedItem != nil else { return }
        let position = currentTime
        let item = currentItem
        chainedItem = nil
        if var item {
            item.startTime = position
            load(item: item, autoplay: isPlaying)
        }
    }

    // MARK: - Transport

    func play() {
        guard currentItem != nil else { return }
        let wasPlaying = isPlaying
        // Another app may have taken the session while we were paused (lock
        // screen resume), so reclaim it before starting the engine.
        session.activate()

        // The hardware changed while we were paused (usually another app
        // switching the sample rate). Rebuild now that the session is ours,
        // then resume from the same spot.
        if graphNeedsRebuild, var item = currentItem {
            graphNeedsRebuild = false
            let sr = AVAudioSession.sharedInstance().sampleRate
            if sr > 0, let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) {
                let resumeAt = currentTime
                resetGraph(to: fmt)
                item.startTime = resumeAt
                load(item: item, autoplay: true)
                return
            }
        }

        ensureEngineRunning()
        // `AVAudioPlayerNode.play()` raises an Objective-C exception - an
        // instant crash Swift cannot catch - when the engine is not running.
        // That is exactly the state after `start()` fails because another app,
        // a phone call or Siri holds the session. Report paused instead.
        guard engine.isRunning else {
            isPlaying = false
            updateTicker()
            if wasPlaying { onPlayStateChanged?(false) }
            return
        }
        if !player.isPlaying {
            let started = sonoraCatch("player.play") { player.play() }
            guard started else {
                isPlaying = false
                updateTicker()
                if wasPlaying { onPlayStateChanged?(false) }
                return
            }
        }
        // Re-anchor extrapolation: frozenTime was captured at pause, and the
        // time spent paused must not count as elapsed playback.
        if !wasPlaying { frozenAt = CACurrentMediaTime() }
        isPlaying = true
        if settings.fadeOnPauseResume {
            activeGain.volume = 0
            startFade(on: activeGain, to: gainLinear(currentItem?.gainDB ?? 0),
                      duration: settings.pauseFadeMS / 1000)
        } else {
            activeGain.volume = gainLinear(currentItem?.gainDB ?? 0)
        }
        updateTicker()
        if !wasPlaying { onPlayStateChanged?(true) }
    }

    func pause(fade doFade: Bool = true) {
        guard isPlaying else { isPlaying = false; return }
        // Pausing mid-crossfade: finish the blend now, otherwise the incoming
        // player keeps playing while the app says "paused".
        if crossfadeRamp != nil { advanceCrossfade(now: .greatestFiniteMagnitude) }
        frozenTime = currentTime
        isPlaying = false
        if doFade && settings.fadeOnPauseResume {
            startFade(on: activeGain, to: 0, duration: settings.pauseFadeMS / 1000) { [weak self] in
                self?.player.pause()
                self?.scheduleEngineIdle()
            }
        } else {
            player.pause()
            scheduleEngineIdle()
        }
        updateTicker()
        onPlayStateChanged?(false)
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func stop() {
        isPlaying = false
        playerA.stop()
        playerB.stop()
        segments.removeAll()
        liveScheduleIDs.removeAll()
        crossfadeScheduleID = nil
        nextScheduleFrame = 0
        currentItem = nil
        chainedItem = nil
        openFiles.removeAll()
        frozenTime = nil
        fade = nil
        crossfadeRamp = nil
        pendingCrossfadeItem = nil
        onTick?(0, 0)
        scheduleEngineIdle()
        updateTicker()
    }

    func seek(to time: TimeInterval) {
        guard var item = currentItem else { return }
        let wasPlaying = isPlaying
        // `startTime` doubles as the resume offset inside the file, so a cue
        // track can never be seeked in front of its own start point. Keep at
        // least a moment of audio ahead of the playhead too: landing on (or
        // past) the end leaves zero frames to schedule, and `load` would bail
        // out with nothing playing at all.
        let ceiling = (item.endTime ?? currentDuration) - 0.25
        item.startTime = max(0, min(time, max(0, ceiling)))
        chainedItem = nil
        load(item: item, autoplay: wasPlaying)
    }

    func skipForward(_ seconds: TimeInterval) { seek(to: currentTime + seconds) }
    func skipBackward(_ seconds: TimeInterval) { seek(to: max(0, currentTime - seconds)) }

    // MARK: - Crossfade

    private func beginCrossfade(to item: PlayableItem) {
        // The incoming node is started below, and play() on a node whose
        // engine is not running raises an uncatchable exception.
        ensureEngineRunning()
        guard engine.isRunning else { return }
        guard let file = openFile(for: item) else { return }

        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return }
        let startFrame = sonoraFramePosition(seconds: item.startTime, sampleRate: sr)
        let endFrame = item.endTime.map { min(file.length, sonoraFramePosition(seconds: $0, sampleRate: sr)) } ?? file.length
        let frames = min(endFrame - startFrame, AVAudioFramePosition(AVAudioFrameCount.max))
        guard startFrame < file.length, frames > 0 else { return }

        let target = idlePlayer
        let targetMixer = idleGain
        target.stop()
        connectPlayer(target, to: targetMixer, format: file.processingFormat)

        openFiles[item.trackID] = file
        targetMixer.volume = 0
        let scheduleID = newScheduleID()
        crossfadeScheduleID = scheduleID
        target.scheduleSegment(file,
                               startingFrame: startFrame,
                               frameCount: AVAudioFrameCount(frames),
                               at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.liveScheduleIDs.remove(scheduleID) != nil else { return }
                self.onFinished?()
            }
        }
        guard engine.isRunning else {
            // Lost the engine between the check above and here (a
            // configuration change). Drop the schedule rather than crash.
            liveScheduleIDs.remove(scheduleID)
            crossfadeScheduleID = nil
            target.stop()
            return
        }
        guard sonoraCatch("crossfade play", { target.play() }) else {
            liveScheduleIDs.remove(scheduleID)
            crossfadeScheduleID = nil
            target.stop()
            return
        }

        pendingCrossfadeItem = item
        crossfadeRamp = (CACurrentMediaTime(), max(0.2, settings.crossfadeSeconds))
        updateTicker()
    }

    private func advanceCrossfade(now: CFTimeInterval) {
        guard let ramp = crossfadeRamp, let incoming = pendingCrossfadeItem else { return }
        let t = min(1, (now - ramp.start) / ramp.duration)
        // Equal-power curve keeps perceived loudness steady through the blend.
        let outGain = Float(cos(t * .pi / 2))
        let inGain = Float(sin(t * .pi / 2))
        activeGain.volume = gainLinear(currentItem?.gainDB ?? 0) * outGain
        idleGain.volume = gainLinear(incoming.gainDB) * inGain

        if t >= 1 {
            // Stopping the outgoing player fires its completion handler; retire
            // its schedule first so that callback cannot be mistaken for the end
            // of the queue. The incoming segment's id stays live.
            liveScheduleIDs = crossfadeScheduleID.map { [$0] } ?? []
            crossfadeScheduleID = nil
            player.stop()
            openFiles.removeValue(forKey: currentItem?.trackID ?? UUID())
            usingA.toggle()
            currentItem = incoming
            currentFormat = openFiles[incoming.trackID]?.processingFormat
            // Frame maths through the non-trapping helper: `duration` comes
            // from tags and may be 0 or garbage.
            let incomingRate = currentFormat?.sampleRate ?? 0
            let rate = incomingRate > 0 ? incomingRate : 48_000
            let incomingSegment = Segment(trackID: incoming.trackID,
                                          startFrame: 0,
                                          frameCount: sonoraFramePosition(seconds: incoming.duration, sampleRate: rate),
                                          fileStartFrame: sonoraFramePosition(seconds: incoming.startTime, sampleRate: rate),
                                          sampleRate: rate)
            segments = [incomingSegment]
            nextScheduleFrame = incomingSegment.frameCount
            pendingCrossfadeItem = nil
            crossfadeRamp = nil
            onAdvanced?(incoming.trackID)
        }
    }

    // MARK: - Fades

    private func startFade(on node: AVAudioMixerNode,
                           to target: Float,
                           duration: Double,
                           completion: (() -> Void)? = nil) {
        fade = (node.volume, target, CACurrentMediaTime(), max(0.01, duration), node, completion)
        updateTicker()
    }

    private func advanceFade(now: CFTimeInterval) {
        guard let f = fade else { return }
        let t = min(1, (now - f.start) / f.duration)
        f.node.volume = f.from + (f.to - f.from) * Float(t)
        if t >= 1 {
            fade = nil
            f.completion?()
        }
    }

    private func gainLinear(_ db: Float) -> Float {
        db == 0 ? 1 : powf(10, db / 20)
    }

    private func applyGain(_ db: Float, to node: AVAudioMixerNode, ramp: Bool) {
        let target = gainLinear(db)
        if ramp {
            startFade(on: node, to: target, duration: 0.05)
        } else {
            node.volume = target
        }
    }

    // MARK: - Position

    /// Playback position within the *current* item, in seconds.
    var currentTime: TimeInterval {
        // During the stale window the node's frame belongs to the old
        // schedule, so report the position we just seeked to rather than a
        // number derived from it.
        if awaitingFirstRender { return currentItem?.startTime ?? 0 }
        guard engine.isRunning, let seg = currentSegment(), let frame = nodeSampleTime() else {
            // Still meant to be playing (e.g. mid route rebuild): extrapolate
            // from the last good reading so resume lands where the audio was.
            if isPlaying, let frozen = frozenTime {
                let elapsed = max(0, CACurrentMediaTime() - frozenAt)
                let projected = frozen + elapsed * Double(settings.playbackRate)
                return min(projected, currentDuration)
            }
            return frozenTime ?? currentItem?.startTime ?? 0
        }
        guard seg.sampleRate > 0 else { return frozenTime ?? currentItem?.startTime ?? 0 }
        let within = Double(frame - seg.startFrame) / seg.sampleRate
        let time = max(0, within) + Double(seg.fileStartFrame) / seg.sampleRate
        // Remember the last good reading for when the engine stops reporting
        // (paused for idle, stopped by an interruption). load()/stop() reset it.
        frozenTime = time
        frozenAt = CACurrentMediaTime()
        return time
    }

    var currentDuration: TimeInterval {
        guard let seg = currentSegment(), seg.sampleRate > 0 else { return currentItem?.duration ?? 0 }
        let full = Double(seg.frameCount) / seg.sampleRate
        return full + Double(seg.fileStartFrame) / seg.sampleRate
    }

    /// Seconds left before the current segment ends.
    var remainingTime: TimeInterval {
        guard let seg = currentSegment(), seg.sampleRate > 0,
              let frame = nodeSampleTime() else { return .greatestFiniteMagnitude }
        return Double(seg.endFrame - frame) / seg.sampleRate
    }

    private func nodeSampleTime() -> AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    private func currentSegment() -> Segment? {
        guard let frame = nodeSampleTime() else { return segments.first }
        for seg in segments where frame >= seg.startFrame && frame < seg.endFrame {
            return seg
        }
        return segments.last
    }

    // MARK: - Ticker

    /// Picks the slowest tick rate that still does the job, or none at all.
    private func desiredTickInterval() -> TimeInterval? {
        if fade != nil || crossfadeRamp != nil { return 1.0 / 30.0 }   // smooth volume ramps
        guard isPlaying else { return nil }                              // idle: no wakeups
        return isForeground ? 0.25 : 1.0
    }

    private func updateTicker() {
        let want = desiredTickInterval()
        if want == tickerInterval && (want == nil) == (ticker == nil) { return }
        ticker?.invalidate()
        ticker = nil
        tickerInterval = want
        guard let want else { return }
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Tolerance lets iOS coalesce our wakeups with other timers.
        t.tolerance = want * 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        advanceFade(now: now)
        advanceCrossfade(now: now)

        defer { updateTicker() }
        guard isPlaying || currentItem != nil else { return }

        // Wait for the node to actually render into the new schedule before
        // trusting its sample time for advance detection.
        if awaitingFirstRender {
            if let frame = nodeSampleTime(), let first = segments.first,
               frame >= first.startFrame, frame < first.endFrame {
                awaitingFirstRender = false
            }
        }

        // Detect gapless segment advance.
        if !awaitingFirstRender,
           let seg = currentSegment(),
           let item = currentItem,
           seg.trackID != item.trackID {
            if let chained = chainedItem, chained.trackID == seg.trackID {
                currentItem = chained
                chainedItem = nil
                applyGain(chained.gainDB, to: activeGain, ramp: true)
                onAdvanced?(chained.trackID)
                maybeChainNext()
            }
        }

        // Start a crossfade when the tail is near.
        if settings.crossfadeEnabled,
           isPlaying,
           !awaitingFirstRender,
           pendingCrossfadeItem == nil,
           !settings.crossfadeOnManualSkipOnly,
           // Look one tick ahead so a slow background ticker never starts late.
           remainingTime <= settings.crossfadeSeconds + (tickerInterval ?? 0),
           remainingTime > 0.05,
           let next = provideNextItem?() {
            beginCrossfade(to: next)
        }

        onTick?(currentTime, currentDuration)
    }

    // MARK: - Metering

    /// Installs a tap for the visualizer. Pass `nil` to remove it.
    /// The controller only installs it while the visualizer is on screen.
    func setMeterTap(_ handler: (([Float]) -> Void)?) {
        // Removing a tap that is not installed is a no-op, so do it
        // unconditionally in case our flag and the node ever disagree.
        engine.mainMixerNode.removeTap(onBus: 0)
        isMeterTapInstalled = false
        guard let handler else { return }
        // installTap raises an Objective-C exception for a 0 Hz / 0 channel
        // bus format (no output route). Skip the visualizer rather than crash.
        let busFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard busFormat.sampleRate > 0, busFormat.channelCount > 0 else { return }

        // Allocated once, up here, instead of on every buffer inside the tap.
        // The old version built a fresh 24-element array and hopped to the
        // main thread ~47 times a second, which both stalled the tap thread
        // and flooded SwiftUI with invalidations.
        let bins = 24
        var levels = [Float](repeating: 0, count: bins)
        var lastPublish: CFTimeInterval = 0

        // `nil` taps the bus in whatever format it has when audio flows. An
        // explicit format captured here goes stale after a graph rebuild at a
        // new sample rate, and a mismatched tap format is another exception.
        let installed = sonoraCatch("installTap") {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let channels = Int(buffer.format.channelCount)
            let per = max(1, frames / bins)

            for b in 0..<bins {
                let start = b * per
                let end = min(frames, start + per)
                guard start < end else { continue }
                var peak: Float = 0
                for c in 0..<channels {
                    var m: Float = 0
                    // vDSP replaces the hand-rolled abs/compare loop; it is
                    // vectorised and keeps this tap well inside its deadline.
                    vDSP_maxmgv(data[c] + start, 1, &m, vDSP_Length(end - start))
                    if m > peak { peak = m }
                }
                // Decay toward the new peak so bars fall smoothly rather than
                // flickering, which also hides the lower publish rate.
                levels[b] = min(1, max(peak, levels[b] * 0.72))
            }

            // Publish at ~15 Hz, not once per buffer. A spectrum display gains
            // nothing above this, and it cuts main-thread wake-ups by two
            // thirds.
            let now = CACurrentMediaTime()
            guard now - lastPublish >= 1.0 / 15.0 else { return }
            lastPublish = now
            let snapshot = levels
            DispatchQueue.main.async { handler(snapshot) }
        }
        }
        isMeterTapInstalled = installed
    }
}
