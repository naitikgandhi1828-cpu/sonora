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

@MainActor
final class PlaybackController: ObservableObject {

    // MARK: Published

    @Published private(set) var queue: [UUID] = []
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentArtwork: UIImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var meterLevels: [Float] = Array(repeating: 0, count: 24)
    @Published private(set) var queueSourceName: String = ""

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

    // MARK: Init

    init(library: MediaLibrary, settings: AppSettings) {
        self.library = library
        self.settings = settings
        self.engine = PlaybackEngine(settings: settings)

        wireEngine()
        wireRemoteCommands()
        wireSleepTimer()
        observeSettings()
        restoreState()
    }

    private func wireEngine() {
        engine.onTick = { [weak self] pos, dur in
            guard let self, !self.isScrubbing else { return }
            self.position = pos
            self.duration = dur > 0 ? dur : (self.currentTrack?.duration ?? 0)
            self.refreshNowPlaying(throttled: true)
        }
        engine.onAdvanced = { [weak self] trackID in
            guard let self else { return }
            if let idx = self.queue.firstIndex(of: trackID) {
                self.currentIndex = idx
            }
            self.setCurrent(trackID: trackID)
            self.library.markPlayed(trackID)
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
        engine.setMeterTap { [weak self] levels in
            guard let self, self.settings.showVisualizer else { return }
            self.meterLevels = levels
        }
    }

    private func wireRemoteCommands() {
        let center = NowPlayingCenter.shared
        center.configure(skipInterval: settings.seekStepSeconds)
        center.onPlay = { [weak self] in self?.play() }
        center.onPause = { [weak self] in self?.pause() }
        center.onToggle = { [weak self] in self?.togglePlayPause() }
        center.onNext = { [weak self] in self?.next(userInitiated: true) }
        center.onPrevious = { [weak self] in self?.previous() }
        center.onSeek = { [weak self] time in self?.seek(to: time) }
        center.onSkipForward = { [weak self] i in self?.engine.skipForward(i) }
        center.onSkipBackward = { [weak self] i in self?.engine.skipBackward(i) }
        center.onChangeRating = { [weak self] rating in
            guard let self, let id = self.currentTrack?.id else { return }
            self.library.setRating(rating, for: id)
            self.setCurrent(trackID: id)
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
                self.settings.masterPreampDB = 0
            }
        }
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

        settings.$keepScreenAwake
            .sink { UIApplication.shared.isIdleTimerDisabled = $0 }
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

    func removeFromQueue(at offsets: IndexSet) {
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

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let currentID = currentTrack?.id
        queue.move(fromOffsets: source, toOffset: destination)
        if let id = currentID, let idx = queue.firstIndex(of: id) { currentIndex = idx }
        engine.invalidateChain()
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
        isPlaying = true
        refreshNowPlaying()
    }

    func pause() {
        engine.pause()
        isPlaying = false
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

    func previous() {
        // Restart the track first, like every other player does.
        if position > settings.rewindOnPrevSeconds {
            seek(to: currentTrack?.cueStart ?? 0)
            return
        }
        if settings.shuffleMode != .off, let last = shuffleHistory.popLast(),
           let idx = queue.firstIndex(of: last) {
            currentIndex = idx
            startCurrent(autoplay: true)
            return
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

    func seek(to time: TimeInterval) {
        let lower = currentTrack?.cueStart ?? 0
        let upper = max(lower, duration)
        let clamped = max(lower, min(time, upper))
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

    func skipForward() { engine.skipForward(settings.seekStepSeconds) }
    func skipBackward() { engine.skipBackward(settings.seekStepSeconds) }

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
        engine.load(item: item, autoplay: autoplay)
        isPlaying = autoplay
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
              let track = library.track(id: trackID),
              track.replayGainTrack == nil,
              let url = library.url(for: track) else { return }

        Task.detached(priority: .utility) {
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
            settings.masterPreampDB = 0
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
            isPlaying = false
            position = 0
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

    private var lastNowPlayingUpdate: CFTimeInterval = 0

    private func refreshNowPlaying(throttled: Bool = false) {
        let now = CACurrentMediaTime()
        if throttled && now - lastNowPlayingUpdate < 1.0 { return }
        lastNowPlayingUpdate = now
        NowPlayingCenter.shared.update(track: currentTrack,
                                       artwork: currentArtwork,
                                       position: position,
                                       duration: duration,
                                       rate: isPlaying ? settings.playbackRate : 0,
                                       queueIndex: currentIndex >= 0 ? currentIndex : nil,
                                       queueCount: queue.isEmpty ? nil : queue.count)
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
        guard now - lastStateSave > 5 else { return }
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
