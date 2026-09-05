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

    // MARK: Callbacks (set by PlaybackController)

    /// The engine crossed into a different scheduled segment.
    var onAdvanced: ((UUID) -> Void)?
    /// Everything scheduled has finished playing.
    var onFinished: (() -> Void)?
    /// Asked when the engine wants a track to chain or crossfade into.
    var provideNextItem: (() -> PlayableItem?)?
    /// Position updates, ~25 Hz, on the main queue.
    var onTick: ((TimeInterval, TimeInterval) -> Void)?
    /// A hard failure that the UI should surface.
    var onError: ((String) -> Void)?

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
        startTicker()
    }

    private func attachNodes() {
        for node in [playerA, playerB, gainA, gainB, sourceMixer] as [AVAudioNode] {
            engine.attach(node)
        }
        for node in chain.orderedNodes { engine.attach(node) }
    }

    private func buildGraph() {
        let fmt = chainFormat

        engine.connect(gainA, to: sourceMixer, format: fmt)
        engine.connect(gainB, to: sourceMixer, format: fmt)

        // Player -> gain connections are (re)made per file format in `connectPlayer`.
        connectPlayer(playerA, to: gainA, format: currentFormat ?? fmt)
        connectPlayer(playerB, to: gainB, format: currentFormat ?? fmt)

        var previous: AVAudioNode = sourceMixer
        for node in chain.orderedNodes {
            engine.connect(previous, to: node, format: fmt)
            previous = node
        }
        engine.connect(previous, to: engine.mainMixerNode, format: fmt)

        engine.prepare()
    }

    private func connectPlayer(_ node: AVAudioPlayerNode,
                               to mixer: AVAudioMixerNode,
                               format: AVAudioFormat) {
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: mixer, format: format)
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

    private func rebuildForCurrentRoute() {
        let sr = AVAudioSession.sharedInstance().sampleRate
        guard sr > 0, abs(sr - chainFormat.sampleRate) > 1 else { return }
        let resumePosition = currentTime
        let wasPlaying = isPlaying
        let item = currentItem

        stopEngineOnly()
        chainFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        for node in chain.orderedNodes { engine.disconnectNodeOutput(node) }
        engine.disconnectNodeOutput(sourceMixer)
        engine.disconnectNodeOutput(gainA)
        engine.disconnectNodeOutput(gainB)
        buildGraph()
        chain.applyAll()

        if var item {
            item.startTime = resumePosition
            load(item: item, autoplay: wasPlaying)
        }
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            onError?("Audio engine failed to start: \(error.localizedDescription)")
        }
    }

    private func stopEngineOnly() {
        playerA.stop()
        playerB.stop()
        engine.stop()
    }

    // MARK: - Loading

    /// Loads and (optionally) starts an item, replacing anything scheduled.
    func load(item: PlayableItem, autoplay: Bool) {
        session.activate()

        guard let file = openFile(for: item) else {
            onError?("Cannot open \(item.url.lastPathComponent)")
            return
        }

        // Try to run the hardware at the file's native rate.
        let fileRate = file.processingFormat.sampleRate
        let achieved = session.preferSampleRate(fileRate)
        // AVAudioSession.sampleRate reports 0 when the session has no active
        // route (during an interruption, or mid route change). Building an
        // AVAudioFormat at 0 Hz returns nil, so the force-unwrap below used to
        // crash. Keep the current format in that case and let the route-change
        // handler rebuild once a real rate exists.
        if achieved > 0, abs(achieved - chainFormat.sampleRate) > 1,
           let rebuilt = AVAudioFormat(standardFormatWithSampleRate: achieved, channels: 2) {
            chainFormat = rebuilt
            for node in chain.orderedNodes { engine.disconnectNodeOutput(node) }
            engine.disconnectNodeOutput(sourceMixer)
            engine.disconnectNodeOutput(gainA)
            engine.disconnectNodeOutput(gainB)
            engine.stop()
            buildGraph()
            chain.applyAll()
        }

        playerA.stop()
        playerB.stop()
        usingA = true
        gainA.volume = 1
        gainB.volume = 0
        crossfadeRamp = nil
        pendingCrossfadeItem = nil
        chainedItem = nil
        segments.removeAll()
        nextScheduleFrame = 0
        openFiles = [item.trackID: file]

        currentFormat = file.processingFormat
        connectPlayer(playerA, to: gainA, format: file.processingFormat)
        connectPlayer(playerB, to: gainB, format: file.processingFormat)

        currentItem = item
        applyGain(item.gainDB, to: gainA, ramp: false)

        guard scheduleOnActivePlayer(item: item, file: file) else { return }

        ensureEngineRunning()
        if autoplay { play() } else { isPlaying = false }
        maybeChainNext()
    }

    private func openFile(for item: PlayableItem) -> AVAudioFile? {
        let scoped = item.url.startAccessingSecurityScopedResource()
        defer { if scoped { /* keep access for the life of the file object */ } }
        do {
            return try AVAudioFile(forReading: item.url)
        } catch {
            print("[Engine] open failed: \(error)")
            return nil
        }
    }

    @discardableResult
    private func scheduleOnActivePlayer(item: PlayableItem, file: AVAudioFile) -> Bool {
        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, item.startTime) * sr)
        let endFrame: AVAudioFramePosition = {
            if let end = item.endTime { return min(file.length, AVAudioFramePosition(end * sr)) }
            return file.length
        }()
        let frames = endFrame - startFrame
        guard frames > 0 else { return false }

        let segment = Segment(trackID: item.trackID,
                              startFrame: nextScheduleFrame,
                              frameCount: frames,
                              fileStartFrame: startFrame,
                              sampleRate: sr)
        segments.append(segment)
        nextScheduleFrame += frames

        let node = player
        node.scheduleSegment(file,
                             startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(frames),
                             at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentFinished(trackID: segment.trackID) }
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
        ensureEngineRunning()
        if !player.isPlaying { player.play() }
        isPlaying = true
        if settings.fadeOnPauseResume {
            activeGain.volume = 0
            startFade(on: activeGain, to: gainLinear(currentItem?.gainDB ?? 0),
                      duration: settings.pauseFadeMS / 1000)
        } else {
            activeGain.volume = gainLinear(currentItem?.gainDB ?? 0)
        }
    }

    func pause(fade doFade: Bool = true) {
        guard isPlaying else { isPlaying = false; return }
        isPlaying = false
        if doFade && settings.fadeOnPauseResume {
            startFade(on: activeGain, to: 0, duration: settings.pauseFadeMS / 1000) { [weak self] in
                self?.player.pause()
            }
        } else {
            player.pause()
        }
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func stop() {
        isPlaying = false
        playerA.stop()
        playerB.stop()
        segments.removeAll()
        nextScheduleFrame = 0
        currentItem = nil
        chainedItem = nil
        openFiles.removeAll()
        onTick?(0, 0)
    }

    func seek(to time: TimeInterval) {
        guard var item = currentItem else { return }
        let wasPlaying = isPlaying
        // `startTime` doubles as the resume offset inside the file, so a cue
        // track can never be seeked in front of its own start point.
        item.startTime = max(0, time)
        chainedItem = nil
        load(item: item, autoplay: wasPlaying)
    }

    func skipForward(_ seconds: TimeInterval) { seek(to: currentTime + seconds) }
    func skipBackward(_ seconds: TimeInterval) { seek(to: max(0, currentTime - seconds)) }

    // MARK: - Crossfade

    private func beginCrossfade(to item: PlayableItem) {
        guard let file = openFile(for: item) else { return }

        let target = idlePlayer
        let targetMixer = idleGain
        target.stop()
        connectPlayer(target, to: targetMixer, format: file.processingFormat)

        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, item.startTime) * sr)
        let endFrame = item.endTime.map { min(file.length, AVAudioFramePosition($0 * sr)) } ?? file.length
        let frames = endFrame - startFrame
        guard frames > 0 else { return }

        openFiles[item.trackID] = file
        targetMixer.volume = 0
        target.scheduleSegment(file,
                               startingFrame: startFrame,
                               frameCount: AVAudioFrameCount(frames),
                               at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.onFinished?() }
        }
        ensureEngineRunning()
        target.play()

        pendingCrossfadeItem = item
        crossfadeRamp = (CACurrentMediaTime(), max(0.2, settings.crossfadeSeconds))
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
            player.stop()
            openFiles.removeValue(forKey: currentItem?.trackID ?? UUID())
            usingA.toggle()
            currentItem = incoming
            currentFormat = openFiles[incoming.trackID]?.processingFormat
            segments = [Segment(trackID: incoming.trackID,
                                startFrame: 0,
                                frameCount: AVAudioFramePosition((incoming.duration) * (currentFormat?.sampleRate ?? 48_000)),
                                fileStartFrame: AVAudioFramePosition(incoming.startTime * (currentFormat?.sampleRate ?? 48_000)),
                                sampleRate: currentFormat?.sampleRate ?? 48_000)]
            nextScheduleFrame = segments[0].frameCount
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
        guard let seg = currentSegment(), let frame = nodeSampleTime() else {
            return currentItem?.startTime ?? 0
        }
        let within = Double(frame - seg.startFrame) / seg.sampleRate
        return max(0, within) + Double(seg.fileStartFrame) / seg.sampleRate
    }

    var currentDuration: TimeInterval {
        guard let seg = currentSegment() else { return currentItem?.duration ?? 0 }
        let full = Double(seg.frameCount) / seg.sampleRate
        return full + Double(seg.fileStartFrame) / seg.sampleRate
    }

    /// Seconds left before the current segment ends.
    var remainingTime: TimeInterval {
        guard let seg = currentSegment(), let frame = nodeSampleTime() else { return .greatestFiniteMagnitude }
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

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        advanceFade(now: now)
        advanceCrossfade(now: now)

        guard isPlaying || currentItem != nil else { return }

        // Detect gapless segment advance.
        if let seg = currentSegment(),
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
           pendingCrossfadeItem == nil,
           !settings.crossfadeOnManualSkipOnly,
           remainingTime <= settings.crossfadeSeconds,
           remainingTime > 0.05,
           let next = provideNextItem?() {
            beginCrossfade(to: next)
        }

        onTick?(currentTime, currentDuration)
    }

    // MARK: - Metering

    /// Installs a tap for the visualizer. Pass `nil` to remove it.
    func setMeterTap(_ handler: (([Float]) -> Void)?) {
        engine.mainMixerNode.removeTap(onBus: 0)
        guard let handler else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)

        // Allocated once, up here, instead of on every buffer inside the tap.
        // The old version built a fresh 24-element array and hopped to the
        // main thread ~47 times a second, which both stalled the tap thread
        // and flooded SwiftUI with invalidations.
        let bins = 24
        var levels = [Float](repeating: 0, count: bins)
        var lastPublish: CFTimeInterval = 0

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
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
}
