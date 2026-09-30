//
//  PlaybackController.swift
//  Sonora
//
//  Owns the play queue and drives the engine. Everything the UI binds to
//  for transport lives here.
//

import Foundation
import Combine
import SwiftUI
import UIKit
import MediaPlayer
import QuartzCore

@MainActor
final class PlaybackController: ObservableObject {

    // MARK: Published

    @Published private(set) var queue: [UUID] = []
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            updateMeterTap()
            applyScreenAwake()
        }
    }
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentArtwork: UIImage?
    @Published private(set) var errorMessage: String?
    /// Meter levels are deliberately NOT @Published here — see MeterState.
    let meters = MeterState()
    @Published private(set) var queueSourceName: String = ""

    // MARK: High-frequency values
    //
    // Position changes several times a second. It is NOT @Published here,
    // because every view observing the controller (the library lists
    // included) would re-render on each change. Views that show progress
    // observe `clock` instead.

    let clock = PlaybackClock()

    private(set) var position: TimeInterval = 0 { didSet { syncClock() } }
    private(set) var duration: TimeInterval = 0 { didSet { syncClock() } }

    private var isForeground = true
    private var visualizerViewers = 0

    /// The order the queue was built in, before shuffling.
    private var unshuffledQueue: [UUID] = []
    private var shuffleHistory: [UUID] = []

    let sleepTimer = SleepTimer()

    // MARK: Dependencies

    private let engine: PlaybackEngine
    private let library: MediaLibrary
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private var isScrubbing = false

    var dsp: DSPChain { engine.chain }

    /// Set once by the app on launch. When it turns up a cover for whatever is
    /// playing, refresh the current track so the player and the lock screen
    /// show it straight away instead of on the next track change.
    var artworkFinder: ArtworkFinder? {
        didSet {
            artworkFinder?.onArtworkFound = { [weak self] albumKey in
                guard let self, let track = self.currentTrack,
                      track.albumKey == albumKey else { return }
                self.setCurrent(trackID: track.id)
                self.refreshNowPlaying()
            }
        }
    }

    // MARK: Init

    init(library: MediaLibrary, settings: AppSettings) {
        self.library = library
        self.settings = settings
        self.engine = PlaybackEngine(settings: settings)

        wireEngine()
        wireRemoteCommands()
        wireSleepTimer()
        observeSettings()
        observeAppLifecycle()
        restoreState()
    }

    private func wireEngine() {
        engine.onTick = { [weak self] pos, dur in
            guard let self, !self.isScrubbing else { return }
            // The engine now ticks at 4 Hz on screen and 1 Hz in the
            // background, and `position` only reaches views through `clock`,
            // so no throttle is needed here.
            self.position = pos
            let newDuration = dur > 0 ? dur : (self.currentTrack?.duration ?? 0)
            if abs(newDuration - self.duration) > 0.001 {
                self.duration = newDuration
            }
            // The lock screen extrapolates elapsed time from the rate we give
            // it, so it only needs updating on real changes (play, pause,
            // seek, track change) — not on every tick.
            self.saveState()
        }
        engine.onAdvanced = { [weak self] trackID in
            guard let self else { return }
            if let idx = self.queue.firstIndex(of: trackID) {
                self.currentIndex = idx
            }
            self.setCurrent(trackID: trackID)
            self.library.markPlayed(trackID)
            self.position = self.engine.currentTime
            self.refreshNowPlaying()
        }
        engine.onFinished = { [weak self] in
            self?.handlePlaybackFinished()
        }
        engine.provideNextItem = { [weak self] in
            guard let self else { return nil }
            return self.itemForIndex(self.indexAfter(self.currentIndex))
        }
        engine.onError = { [weak self] message in
            self?.errorMessage = message
        }
        // Interruptions and headphone unplug/plug pause or resume inside the
        // engine; mirror that here so the UI and lock screen stay truthful.
        engine.onPlayStateChanged = { [weak self] playing in
            guard let self, self.isPlaying != playing else { return }
            self.position = self.engine.currentTime
            self.isPlaying = playing
            self.refreshNowPlaying()
        }
        // The meter tap is no longer installed here permanently; see
        // updateMeterTap(), which only runs it while the visualizer is visible.
    }

    // MARK: - Power-aware UI plumbing

    private func syncClock() {
        guard isForeground else { return }   // nobody can see it in the background
        clock.update(position: position, duration: duration)
    }

    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        nc.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.setForeground(false) }
            .store(in: &cancellables)
        nc.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.setForeground(true) }
            .store(in: &cancellables)
    }

    private func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        engine.isForeground = foreground
        if foreground {
            clock.update(position: position, duration: duration)
        }
        updateMeterTap()
    }

    /// Called by the visualizer as it appears and disappears. A counter, so a
    /// new instance appearing before the old one disappears never switches
    /// the tap off under visible bars.
    func setVisualizerVisible(_ visible: Bool) {
        visualizerViewers = max(0, visualizerViewers + (visible ? 1 : -1))
        updateMeterTap()
    }

    /// The meter tap costs CPU on every audio buffer, so it only exists while
    /// the visualizer is actually on screen and music is playing.
    private func updateMeterTap() {
        let wanted = visualizerViewers > 0 && isForeground && isPlaying && settings.visualizerAllowed
        guard wanted != engine.isMeterTapInstalled else { return }
        if wanted {
            engine.setMeterTap { [weak self] levels in
                self?.meters.levels = levels
            }
        } else {
            engine.setMeterTap(nil)
            if meters.levels.contains(where: { $0 != 0 }) {
                meters.levels = Array(repeating: 0, count: meters.levels.count)
            }
        }
    }

    private func powerSettingsChanged() {
        updateMeterTap()
        applyScreenAwake()
    }

    private func applyScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = settings.effectiveKeepScreenAwake && isPlaying
    }

    private func wireRemoteCommands() {
        let center = NowPlayingCenter.shared
        center.configure(skipInterval: settings.seekStepSeconds)
        center.onPlay = { [weak self] in self?.play() }
        center.onPause = { [weak self] in self?.pause() }
        center.onToggle = { [weak self] in self?.togglePlayPause() }
        center.onNext = { [weak self] in self?.next(userInitiated: true) }
        center.onPrevious = { [weak self] in self?.previous() }
        // The lock screen is told the track's own timeline, so the scrubber
        // hands back a track-relative time and it has to be put back into the
        // file's timeline before the engine sees it.
        center.onSeek = { [weak self] time in
            guard let self else { return }
            self.seek(to: self.trackStart + time)
        }
        center.onSkipForward = { [weak self] i in self?.skip(by: i) }
        center.onSkipBackward = { [weak self] i in self?.skip(by: -i) }
        center.onChangeRating = { [weak self] rating in
            guard let self, let id = self.currentTrack?.id else { return }
            self.library.setRating(rating, for: id)
            self.setCurrent(trackID: id)
            self.refreshNowPlaying()
        }
        // Shuffle / repeat from CarPlay's Now Playing screen.
        center.onShuffle = { [weak self] on in
            self?.settings.shuffleMode = on ? .tracks : .off
        }
        center.onRepeat = { [weak self] type in
            guard let self else { return }
            switch type {
            case .one: self.settings.repeatMode = .one
            case .all: self.settings.repeatMode = .all
            default: self.settings.repeatMode = .off
            }
        }
        center.setSkipButtons(settings.lockScreenSkipButtons)
    }

    /// The app's repeat mode as the lock screen / CarPlay understand it.
    private var remoteRepeatType: MPRepeatType {
        switch settings.repeatMode {
        case .one: return .one
        case .all: return .all
        default: return .off
        }
    }

    private func wireSleepTimer() {
        // The timer is its own observable object, so forward its changes to
        // anyone observing the controller.
        sleepTimer.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        sleepTimer.onFade = { [weak self] multiplier in
            guard let self else { return }
            // SleepTimer.cancel() signals "undo the fade" by sending 1.
            // Previously that landed as 20*log10(1) = 0 dB, so cancelling a
            // timer silently reset the user's pre-amp too.
            if multiplier >= 1 {
                self.restorePreampAfterSleep()
                return
            }
            // Remember the user's own pre-amp before overwriting it, so the
            // fade can be undone. Restoring a hard 0 discarded their setting
            // every time the sleep timer ran.
            if self.preSleepPreampDB == nil {
                self.preSleepPreampDB = self.settings.masterPreampDB
            }
            // Ride the master pre-amp down for a graceful fade.
            let db = multiplier <= 0 ? -60 : 20 * log10(max(multiplier, 0.001))
            self.settings.masterPreampDB = max(-24, min(0, db))
        }
        sleepTimer.onExpire = { [weak self] in
            guard let self else { return }
            if self.sleepTimer.finishTrackFirst && self.isPlaying {
                // Let the current track run out, then stop.
                self.stopAfterCurrent = true
            } else {
                self.pause()
                self.restorePreampAfterSleep()
            }
        }
    }

    /// Pre-amp value from before the sleep-timer fade started, if any.
    private var preSleepPreampDB: Double?

    private func restorePreampAfterSleep() {
        // Only undo a fade that actually happened; otherwise leave the user's
        // pre-amp exactly where they set it.
        guard let saved = preSleepPreampDB else { return }
        settings.masterPreampDB = saved
        preSleepPreampDB = nil
    }

    private var stopAfterCurrent = false

    private func observeSettings() {
        settings.$shuffleMode
            .dropFirst()
            .sink { [weak self] mode in self?.applyShuffle(mode) }
            .store(in: &cancellables)

        settings.$repeatMode
            .dropFirst()
            .sink { [weak self] _ in self?.engine.invalidateChain() }
            .store(in: &cancellables)

        settings.$replayGainMode
            .dropFirst()
            .sink { [weak self] _ in self?.engine.invalidateChain() }
            .store(in: &cancellables)

        // Anything that changes what battery saver allows. @Published fires
        // before the new value is stored, so hop to the next run-loop turn.
        settings.$keepScreenAwake
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.powerSettingsChanged() }
            .store(in: &cancellables)
        settings.$showVisualizer
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.powerSettingsChanged() }
            .store(in: &cancellables)
        settings.$powerMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.powerSettingsChanged() }
            .store(in: &cancellables)
        settings.$systemLowPowerMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.powerSettingsChanged() }
            .store(in: &cancellables)

        // Keep CarPlay / lock-screen shuffle, repeat and button style in step.
        Publishers.Merge(settings.$shuffleMode.map { _ in true },
                         settings.$repeatMode.map { _ in true })
            .dropFirst(2)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshNowPlaying() }
            .store(in: &cancellables)
        settings.$lockScreenSkipButtons
            .dropFirst()
            .sink { NowPlayingCenter.shared.setSkipButtons($0) }
            .store(in: &cancellables)

        settings.$playbackRate
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshNowPlaying() }
            .store(in: &cancellables)
    }

    // MARK: - Queue building

    /// Replaces the queue and starts at `startIndex`.
    func play(trackIDs: [UUID], startIndex: Int = 0, sourceName: String = "") {
        guard !trackIDs.isEmpty else { return }
        unshuffledQueue = trackIDs
        queueSourceName = sourceName
        shuffleHistory.removeAll()

        if settings.shuffleMode == .off {
            queue = trackIDs
            currentIndex = max(0, min(startIndex, queue.count - 1))
        } else {
            let anchor = trackIDs[max(0, min(startIndex, trackIDs.count - 1))]
            queue = shuffled(trackIDs, keepingFirst: anchor)
            currentIndex = 0
        }
        startCurrent(autoplay: true)
    }

    func playAlbum(_ album: AlbumGroup) {
        let ordered = library.tracks(ids: album.trackIDs)
            .sorted(by: TrackSort.trackNumber.comparator(ascending: true))
            .map(\.id)
        play(trackIDs: ordered, startIndex: 0, sourceName: album.title)
    }

    func enqueue(_ trackIDs: [UUID], playNext: Bool) {
        guard !trackIDs.isEmpty else { return }
        if queue.isEmpty {
            play(trackIDs: trackIDs)
            return
        }
        let insertAt = playNext ? min(currentIndex + 1, queue.count) : queue.count
        queue.insert(contentsOf: trackIDs, at: insertAt)
        unshuffledQueue.append(contentsOf: trackIDs)
        engine.invalidateChain()
    }

    func removeFromQueue(at rawOffsets: IndexSet) {
        // Offsets come from a List that may have been rendered against an
        // older queue; `remove(atOffsets:)` and the subscript below trap on
        // anything out of range.
        let offsets = IndexSet(rawOffsets.filter { queue.indices.contains($0) })
        guard !offsets.isEmpty else { return }
        let removingCurrent = offsets.contains(currentIndex)
        let idsBefore = queue
        queue.remove(atOffsets: offsets)
        let removed = Set(offsets.map { idsBefore[$0] })
        unshuffledQueue.removeAll { removed.contains($0) }

        if queue.isEmpty { stop(); return }
        if removingCurrent {
            currentIndex = min(currentIndex, queue.count - 1)
            startCurrent(autoplay: isPlaying)
        } else if let id = currentTrack?.id, let idx = queue.firstIndex(of: id) {
            currentIndex = idx
            engine.invalidateChain()
        }
    }

    func moveInQueue(from rawSource: IndexSet, to rawDestination: Int) {
        // Same stale-offset hazard as removal: `move(fromOffsets:toOffset:)`
        // traps on an out-of-range index.
        let source = IndexSet(rawSource.filter { queue.indices.contains($0) })
        guard !source.isEmpty else { return }
        let destination = max(0, min(rawDestination, queue.count))
        let currentID = currentTrack?.id
        queue.move(fromOffsets: source, toOffset: destination)
        if let id = currentID, let idx = queue.firstIndex(of: id) { currentIndex = idx }
        engine.invalidateChain()
    }

    /// Drops queue entries whose tracks have left the library (for example
    /// after a folder is removed). Stops playback if the current track went.
    func pruneQueue() {
        let exists: (UUID) -> Bool = { [library] in library.track(id: $0) != nil }
        guard queue.contains(where: { !exists($0) }) else { return }
        let currentID = currentTrack?.id
        queue.removeAll { !exists($0) }
        unshuffledQueue.removeAll { !exists($0) }
        shuffleHistory.removeAll { !exists($0) }
        if let currentID, exists(currentID), let idx = queue.firstIndex(of: currentID) {
            currentIndex = idx
            engine.invalidateChain()
        } else {
            stop()
            if queue.isEmpty { queueSourceName = "" }
        }
    }

    func clearQueue() {
        stop()
        queue.removeAll()
        unshuffledQueue.removeAll()
        queueSourceName = ""
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        startCurrent(autoplay: true)
    }

    // MARK: - Transport

    func play() {
        if currentTrack == nil, !queue.isEmpty {
            currentIndex = max(0, currentIndex)
            startCurrent(autoplay: true)
            return
        }
        engine.play()
        // The engine refuses to play (rather than crash) when the audio
        // session cannot be activated, so mirror what it actually did.
        isPlaying = engine.isPlaying
        position = engine.currentTime
        refreshNowPlaying()
    }

    func pause() {
        engine.pause()
        isPlaying = false
        position = engine.currentTime
        refreshNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func stop() {
        engine.stop()
        isPlaying = false
        position = 0
        currentTrack = nil
        currentArtwork = nil
        currentIndex = -1
        NowPlayingCenter.shared.clear()
    }

    func next(userInitiated: Bool = false) {
        let target = indexAfter(currentIndex, userInitiated: userInitiated)
        guard let target else {
            if settings.repeatMode == .off { pause(); position = 0 }
            return
        }
        currentIndex = target
        startCurrent(autoplay: true)
    }

    /// - Parameter allowRestart: when true (the transport button) a right-hand
    ///   press part-way through a track restarts it, the way every other player
    ///   behaves. The artwork swipe passes false: the cover has already slid
    ///   across to the previous album, so snapping back to the same song would
    ///   contradict what the user just watched happen.
    func previous(allowRestart: Bool = true) {
        if allowRestart, elapsed > settings.rewindOnPrevSeconds {
            seek(to: currentTrack?.cueStart ?? 0)
            return
        }
        if settings.shuffleMode != .off {
            // The history always ends with the song that is playing now
            // (startCurrent appends it), so popping once just restarted the
            // current song and Previous never went back. Drop the current
            // song first, then step to the one before it.
            let currentID = currentTrack?.id
            while let last = shuffleHistory.last, last == currentID {
                shuffleHistory.removeLast()
            }
            while let previousID = shuffleHistory.popLast() {
                if let idx = queue.firstIndex(of: previousID) {
                    currentIndex = idx
                    startCurrent(autoplay: true)
                    return
                }
            }
            // No history left: fall through to plain queue order.
        }
        if currentIndex > 0 {
            currentIndex -= 1
        } else if settings.repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        startCurrent(autoplay: true)
    }

    // MARK: - Track-relative position
    //
    // `position` and `duration` are positions *in the file*. For an ordinary
    // file that is also the position in the track, but a cue-sheet track is a
    // slice out of the middle of one long rip: the third track of a set might
    // run from 12:40 to 17:05 of the file. Anything the listener sees - the
    // seek bar, the timecodes, the mini player - has to work in the track's own
    // timeline, which is what these three provide.

    /// Where the current track starts inside its file.
    var trackStart: TimeInterval { currentTrack?.cueStart ?? 0 }

    /// Where it ends inside its file.
    var trackEnd: TimeInterval {
        max(trackStart + 0.01, currentTrack?.cueEnd ?? duration)
    }

    /// Length of the track itself.
    var trackLength: TimeInterval { trackEnd - trackStart }

    /// How far into the track we are.
    var elapsed: TimeInterval { elapsed(at: position) }

    /// Track-relative time for a file position (used by views that read the
    /// live position from `clock`).
    func elapsed(at filePosition: TimeInterval) -> TimeInterval {
        min(max(0, filePosition - trackStart), trackLength)
    }

    // MARK: - Queue neighbours (for the player's swipe transition)

    var canGoNext: Bool { indexAfter(currentIndex, userInitiated: true) != nil }

    var canGoPrevious: Bool {
        guard !queue.isEmpty else { return false }
        if settings.shuffleMode != .off,
           shuffleHistory.contains(where: { $0 != currentTrack?.id }) { return true }
        return currentIndex > 0 || settings.repeatMode == .all
    }

    /// Artwork of the track `offset` places along the queue.
    ///
    /// Best effort by design: under shuffle the track that actually plays next
    /// is not chosen until you get there, so this is what the swipe shows, not
    /// a promise about what will play.
    func artworkKey(offsetBy offset: Int) -> String? {
        let index = currentIndex + offset
        guard queue.indices.contains(index),
              let track = library.track(id: queue[index]) else { return nil }
        return track.artworkKey
    }

    func seek(to time: TimeInterval) {
        let clamped = max(trackStart, min(time, trackEnd))
        position = clamped
        engine.seek(to: clamped)
        refreshNowPlaying()
    }

    func beginScrub() { isScrubbing = true }

    func endScrub(at time: TimeInterval) {
        isScrubbing = false
        seek(to: time)
    }

    func scrubPreview(_ time: TimeInterval) {
        position = time
    }

    func skipForward() { skip(by: settings.seekStepSeconds) }
    func skipBackward() { skip(by: -settings.seekStepSeconds) }

    /// Nudges the playhead, clamped to the track rather than to the file.
    /// Skipping back off the front of a cue track used to land in the previous
    /// track's audio while the UI still showed this one.
    private func skip(by seconds: TimeInterval) {
        seek(to: engine.currentTime + seconds)
    }

    func cycleRepeat() { settings.repeatMode = settings.repeatMode.next }
    func cycleShuffle() { settings.shuffleMode = settings.shuffleMode.next }

    // MARK: - Internals

    private func startCurrent(autoplay: Bool) {
        guard queue.indices.contains(currentIndex),
              let item = itemForIndex(currentIndex) else {
            errorMessage = "That file could not be opened."
            return
        }
        setCurrent(trackID: queue[currentIndex])
        position = item.startTime
        engine.load(item: item, autoplay: autoplay)
        isPlaying = autoplay && engine.isPlaying
        library.markPlayed(queue[currentIndex])
        if settings.shuffleMode != .off {
            shuffleHistory.append(queue[currentIndex])
            if shuffleHistory.count > 200 { shuffleHistory.removeFirst() }
        }
        refreshNowPlaying()
        analyzeGainIfNeeded(for: queue[currentIndex])
    }

    private func setCurrent(trackID: UUID) {
        guard let track = library.track(id: trackID) else { return }
        currentTrack = track
        currentArtwork = ArtworkStore.shared.image(forKey: track.artworkKey)
        duration = track.duration
        // Albums that came in without a cover get one looked up in the
        // background the first time something from them plays.
        artworkFinder?.findIfMissing(for: track)
    }

    /// Re-reads the playing track from the library after its tags or cover
    /// were edited, so Now Playing, the mini player and the lock screen show
    /// the new values straight away. Playback itself is untouched.
    func refreshCurrentTrackFromLibrary() {
        guard let current = currentTrack,
              let fresh = library.track(id: current.id) else { return }
        currentTrack = fresh
        if fresh.artworkKey != current.artworkKey || currentArtwork == nil {
            currentArtwork = ArtworkStore.shared.image(forKey: fresh.artworkKey)
        }
        refreshNowPlaying()
    }

    private func itemForIndex(_ index: Int?) -> PlayableItem? {
        guard let index, queue.indices.contains(index),
              let track = library.track(id: queue[index]) else { return nil }
        return library.playableItem(for: track, gainDB: replayGain(for: track))
    }

    private func replayGain(for track: Track) -> Float {
        guard settings.replayGainMode != .off else { return 0 }
        var gain: Float
        switch settings.replayGainMode {
        case .off:
            return 0
        case .track:
            gain = track.replayGainTrack ?? Float(settings.replayGainFallbackDB)
        case .album:
            gain = track.replayGainAlbum ?? track.replayGainTrack ?? Float(settings.replayGainFallbackDB)
        case .smart:
            // Album gain when the queue is an intact album, track gain otherwise.
            let sameAlbum = queue.compactMap { library.track(id: $0) }
                                 .allSatisfy { $0.albumKey == track.albumKey }
            gain = sameAlbum ? (track.replayGainAlbum ?? track.replayGainTrack ?? Float(settings.replayGainFallbackDB))
                             : (track.replayGainTrack ?? Float(settings.replayGainFallbackDB))
        }
        gain += Float(settings.replayGainPreampDB)
        if settings.preventClipping, let peak = track.peakTrack, peak > 0 {
            let headroom = -20 * log10f(peak)
            gain = min(gain, headroom)
        }
        return max(-24, min(24, gain))
    }

    private func analyzeGainIfNeeded(for trackID: UUID) {
        guard settings.autoAnalyzeGain,
              PowerState.mayRunHeavyWork(settings: settings),
              let track = library.track(id: trackID),
              track.replayGainTrack == nil,
              let url = library.url(for: track) else { return }

        // .background keeps this on the efficiency cores.
        Task.detached(priority: .background) {
            guard let result = LoudnessAnalyzer.analyze(url: url,
                                                        startTime: track.cueStart ?? 0,
                                                        endTime: track.cueEnd) else { return }
            await MainActor.run {
                self.library.setMeasuredGain(result.gainDB, peak: result.peak, for: trackID)
            }
        }
    }

    private func indexAfter(_ index: Int, userInitiated: Bool = false) -> Int? {
        guard !queue.isEmpty else { return nil }
        if stopAfterCurrent { return nil }
        switch settings.repeatMode {
        case .one where !userInitiated:
            return index
        case .stopAfterCurrent where !userInitiated:
            return nil
        default:
            break
        }
        let next = index + 1
        if next < queue.count { return next }
        if settings.repeatMode == .all { return 0 }
        if settings.shuffleMode != .off && settings.repeatMode == .all { return 0 }
        return nil
    }

    private func handlePlaybackFinished() {
        if stopAfterCurrent {
            stopAfterCurrent = false
            pause()
            restorePreampAfterSleep()
            return
        }
        if settings.repeatMode == .stopAfterCurrent {
            pause()
            return
        }
        if settings.repeatMode == .one {
            seek(to: currentTrack?.cueStart ?? 0)
            engine.play()
            return
        }
        guard let target = indexAfter(currentIndex) else {
            // End of the queue: let the engine go idle instead of rendering
            // silence, and re-arm the track so a later tap on play works.
            engine.pause(fade: false)
            engine.seek(to: currentTrack?.cueStart ?? 0)
            isPlaying = false
            position = currentTrack?.cueStart ?? 0
            refreshNowPlaying()
            return
        }
        // Gapless already advanced us if the engine chained the next file.
        if target != currentIndex {
            currentIndex = target
            startCurrent(autoplay: true)
        }
    }

    private func applyShuffle(_ mode: ShuffleMode) {
        guard !queue.isEmpty else { return }
        let currentID = currentTrack?.id
        switch mode {
        case .off:
            queue = unshuffledQueue
        case .tracks:
            queue = shuffled(unshuffledQueue, keepingFirst: currentID)
        case .albums:
            queue = shuffledByAlbum(unshuffledQueue, keepingFirst: currentID)
        }
        if let id = currentID, let idx = queue.firstIndex(of: id) { currentIndex = idx }
        shuffleHistory.removeAll()
        engine.invalidateChain()
    }

    private func shuffled(_ ids: [UUID], keepingFirst anchor: UUID?) -> [UUID] {
        var rest = ids.shuffled()
        guard let anchor, let idx = rest.firstIndex(of: anchor) else { return rest }
        rest.remove(at: idx)
        return [anchor] + rest
    }

    private func shuffledByAlbum(_ ids: [UUID], keepingFirst anchor: UUID?) -> [UUID] {
        var groups: [String: [UUID]] = [:]
        for id in ids {
            guard let t = library.track(id: id) else { continue }
            groups[t.albumKey, default: []].append(id)
        }
        for key in groups.keys {
            groups[key] = library.tracks(ids: groups[key] ?? [])
                .sorted(by: TrackSort.trackNumber.comparator(ascending: true))
                .map(\.id)
        }
        var order = Array(groups.keys).shuffled()
        if let anchor, let t = library.track(id: anchor),
           let idx = order.firstIndex(of: t.albumKey) {
            order.remove(at: idx)
            order.insert(t.albumKey, at: 0)
        }
        return order.flatMap { groups[$0] ?? [] }
    }

    // MARK: - Now playing

    private func refreshNowPlaying() {
        // Hand the lock screen a fresh elapsed time rather than whatever the
        // last (possibly 1 Hz background) tick left in `position`.
        if !isScrubbing, currentTrack != nil { position = engine.currentTime }
        NowPlayingCenter.shared.update(track: currentTrack,
                                       artwork: currentArtwork,
                                       position: elapsed,
                                       duration: trackLength,
                                       rate: isPlaying ? settings.playbackRate : 0,
                                       queueIndex: currentIndex >= 0 ? currentIndex : nil,
                                       queueCount: queue.isEmpty ? nil : queue.count)
        NowPlayingCenter.shared.updateModes(shuffle: settings.shuffleMode != .off,
                                            repeatType: remoteRepeatType)
        saveState()
    }

    // MARK: - Resume state

    private struct SavedState: Codable {
        var queue: [UUID]
        var unshuffled: [UUID]
        var index: Int
        var position: TimeInterval
        var sourceName: String
    }

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("SonoraPlaybackState.json")
    }

    private var lastStateSave: CFTimeInterval = 0

    private func saveState() {
        let now = CACurrentMediaTime()
        // Resume state is also written when the app backgrounds, so a slow
        // cadence here only guards against crashes.
        guard now - lastStateSave > 30 else { return }
        lastStateSave = now
        let state = SavedState(queue: queue, unshuffled: unshuffledQueue,
                               index: currentIndex, position: position,
                               sourceName: queueSourceName)
        let url = stateURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func restoreState() {
        guard settings.resumeOnLaunch,
              let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data),
              !state.queue.isEmpty else { return }

        queue = state.queue.filter { library.track(id: $0) != nil }
        unshuffledQueue = state.unshuffled.filter { library.track(id: $0) != nil }
        queueSourceName = state.sourceName
        guard queue.indices.contains(state.index) else { return }
        currentIndex = state.index
        setCurrent(trackID: queue[state.index])

        guard let track = library.track(id: queue[state.index]),
              var item = library.playableItem(for: track, gainDB: replayGain(for: track)) else { return }
        item.startTime = max(track.cueStart ?? 0, state.position)
        position = state.position
        engine.load(item: item, autoplay: false)
        isPlaying = false
        refreshNowPlaying()
    }

    func persistNow() {
        lastStateSave = 0
        saveState()
    }
}
