//
//  MediaLibrary.swift
//  Sonora
//
//  The observable store for everything the app knows about the user's music:
//  roots, tracks, playlists and the derived album / artist / folder views.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class MediaLibrary: ObservableObject {

    // MARK: Published state

    @Published private(set) var roots: [FolderRoot] = []
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []

    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var scanStatus: String = ""
    @Published private(set) var lastScanSkipped: [String] = []

    @Published var recentlyPlayedIDs: [UUID] = []

    // Duplicates. `tracks` holds only what the library shows; copies merged
    // into another song live in `hiddenTracks` and can still be looked up
    // (and played) by id, so nothing that points at them breaks.
    /// Pairs Sonora is not sure about and wants the user to decide.
    @Published private(set) var duplicateQuestions: [DuplicateQuestion] = []
    /// Songs that have other copies hidden behind them.
    @Published private(set) var mergedGroups: [MergedSongGroup] = []
    /// The user's answers and "always do this" rules.
    @Published private(set) var duplicateMemory = DuplicateMemory()
    private var hiddenTracks: [Track] = []
    private var hiddenIndex: [UUID: Int] = [:]
    /// Hidden copy → the song it is merged into.
    private var keeperOfHidden: [UUID: UUID] = [:]
    private var songKeyCache: [DuplicateFinder.RawTags: SongKey] = [:]

    private let indexer = LibraryIndexer()
    private let settings: AppSettings
    private var trackIndex: [UUID: Int] = [:]
    private var saveWorkItem: DispatchWorkItem?

    /// Tag edits made in Sonora, keyed by `tagOverrideKey(for:)`. Applied on
    /// top of freshly read metadata every time a file is (re)indexed, so
    /// edits survive rescans for formats Sonora cannot write, for cue-sheet
    /// tracks, and for writes that failed. Removed once a write succeeds.
    private(set) var tagOverrides: [String: TagSet] = [:]
    /// Covers chosen in the tag editor, same keys. An empty string means the
    /// user removed the cover on purpose.
    private(set) var artworkOverrides: [String: String] = [:]

    // MARK: Init

    init(settings: AppSettings) {
        self.settings = settings
        load()
        loadOverrides()
        loadDuplicates()
        // Shortly after launch rather than during it: this is where a library
        // from an older version gets its duplicates merged for the first time.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            await self.warmSongKeys(for: self.tracks + self.hiddenTracks)
            guard !self.isScanning else { return }
            self.reconcileDuplicates()
            self.save()
        }
    }

    // MARK: - Lookup

    func track(id: UUID) -> Track? {
        if let idx = liveIndex(of: id) { return tracks[idx] }
        // A copy that was merged into another song: still a real file.
        if let idx = hiddenIndex[id], hiddenTracks.indices.contains(idx),
           hiddenTracks[idx].id == id {
            return hiddenTracks[idx]
        }
        return nil
    }

    func tracks(ids: [UUID]) -> [Track] {
        ids.compactMap { track(id: $0) }
    }

    /// Resolves a playable file URL for a track, opening the security scope.
    func url(for track: Track) -> URL? {
        if let bookmark = track.standaloneBookmark {
            return FolderAccessManager.shared.resolveStandalone(bookmark)
        }
        guard let rootID = track.rootID,
              let root = roots.first(where: { $0.id == rootID }),
              let base = FolderAccessManager.shared.resolve(root) else { return nil }
        return base.appendingPathComponent(track.relativePath)
    }

    func playableItem(for track: Track, gainDB: Float) -> PlayableItem? {
        guard let url = url(for: track) else { return nil }
        return PlayableItem(trackID: track.id,
                            url: url,
                            startTime: track.cueStart ?? 0,
                            endTime: track.cueEnd,
                            gainDB: gainDB,
                            duration: track.duration)
    }

    // MARK: - Roots

    func addRoot(url: URL) async {
        guard let bookmark = FolderAccessManager.shared.makeBookmark(for: url) else {
            scanStatus = "Could not keep access to that folder."
            return
        }
        if roots.contains(where: { $0.lastKnownPath == url.path }) {
            scanStatus = "That folder is already in your library."
            return
        }
        let root = FolderRoot(displayName: url.lastPathComponent,
                              bookmark: bookmark,
                              lastKnownPath: url.path)
        roots.append(root)
        await rescan(rootID: root.id)
        save()
    }

    /// Makes sure a folder inside Sonora's own Documents folder (the Google
    /// Drive downloads) is one of the library's roots, and returns its id.
    /// Unlike `addRoot` it does not scan; call `rescan(rootID:)` afterwards.
    @discardableResult
    func ensureAppFolderRoot(relativePath: String, displayName: String) -> UUID {
        if let existing = roots.first(where: { $0.appRelativePath == relativePath }) {
            return existing.id
        }
        let url = FolderAccessManager.documentsFolder
            .appendingPathComponent(relativePath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The same folder added earlier by hand through the Files picker:
        // adopt it rather than listing the music twice.
        if let idx = roots.firstIndex(where: { $0.lastKnownPath == url.path }) {
            roots[idx].appRelativePath = relativePath
            FolderAccessManager.shared.release(roots[idx].id)
            save()
            return roots[idx].id
        }
        // The bookmark is never used for this root (see FolderAccessManager),
        // so an empty one is fine if iOS refuses to make it.
        var root = FolderRoot(displayName: displayName,
                              bookmark: FolderAccessManager.shared.makeBookmark(for: url) ?? Data(),
                              lastKnownPath: url.path)
        root.appRelativePath = relativePath
        roots.append(root)
        save()
        return root.id
    }

    /// The root registered with `ensureAppFolderRoot`, if it is still there.
    func appFolderRoot(relativePath: String) -> FolderRoot? {
        roots.first { $0.appRelativePath == relativePath }
    }

    func removeRoot(_ root: FolderRoot) {
        FolderAccessManager.shared.release(root.id)
        let removedIDs = Set(tracks.filter { $0.rootID == root.id }.map(\.id))
        tracks.removeAll { $0.rootID == root.id }
        hiddenTracks.removeAll { $0.rootID == root.id }
        roots.removeAll { $0.id == root.id }
        for i in playlists.indices {
            playlists[i].trackIDs.removeAll { removedIDs.contains($0) }
        }
        playlists.removeAll { $0.trackIDs.isEmpty && $0.importedFrom != nil }
        recentlyPlayedIDs.removeAll { removedIDs.contains($0) }
        let prefix = root.id.uuidString + "|"
        let hadOverrides = tagOverrides.keys.contains { $0.hasPrefix(prefix) }
            || artworkOverrides.keys.contains { $0.hasPrefix(prefix) }
        if hadOverrides {
            tagOverrides = tagOverrides.filter { !$0.key.hasPrefix(prefix) }
            artworkOverrides = artworkOverrides.filter { !$0.key.hasPrefix(prefix) }
            saveOverrides()
        }
        rebuildIndex()
        // A copy that was hidden behind a song in this folder comes back.
        reconcileDuplicates()
        save()
    }

    /// Imports individual files (Files app "Open in" or the document picker).
    func importFiles(urls: [URL]) async {
        isScanning = true
        defer { isScanning = false; scanProgress = 0; scanStatus = "" }

        var added = 0
        for (i, url) in urls.enumerated() {
            scanProgress = Double(i) / Double(max(1, urls.count))
            scanStatus = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard AudioFormats.isPlayable(ext) else { continue }

            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard var info = await MetadataReader.read(url: url,
                                                       rootID: nil,
                                                       relativePath: url.lastPathComponent) else { continue }
            info.track.standaloneBookmark = FolderAccessManager.shared.makeBookmark(for: url)
            if let data = info.artwork {
                info.track.artworkKey = ArtworkStore.shared.store(data, forAlbumKey: info.track.albumKey)
            }
            applyOverrides(to: &info.track)
            if tracks.contains(where: { $0.standaloneBookmark != nil && $0.fileName == info.track.fileName
                                        && abs($0.duration - info.track.duration) < 0.5 }) {
                continue
            }
            tracks.append(info.track)
            added += 1
        }
        rebuildIndex()
        if added > 0 { reconcileDuplicates() }
        save()
        scanStatus = added > 0 ? "Added \(added) file\(added == 1 ? "" : "s")" : "Nothing new to add"
    }

    /// Picks up anything the user dropped into the app's Documents folder
    /// through the Files app.
    func importDocumentsFolder() async {
        let docs = FolderAccessManager.documentsFolder
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: docs,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return }
        let audio = entries.filter { AudioFormats.isPlayable($0.pathExtension) }
        guard !audio.isEmpty else { return }

        var added = 0
        for url in audio {
            let relative = url.lastPathComponent
            if tracks.contains(where: { $0.rootID == nil && $0.relativePath == relative }) { continue }
            guard var info = await MetadataReader.read(url: url, rootID: nil, relativePath: relative) else { continue }
            info.track.standaloneBookmark = FolderAccessManager.shared.makeBookmark(for: url)
            if let data = info.artwork {
                info.track.artworkKey = ArtworkStore.shared.store(data, forAlbumKey: info.track.albumKey)
            }
            applyOverrides(to: &info.track)
            tracks.append(info.track)
            added += 1
        }
        if added > 0 {
            rebuildIndex()
            reconcileDuplicates()
            save()
        }
    }

    /// Adds specific files under a root to the library without rescanning
    /// the whole folder. Used after Google Drive downloads: reading tags for
    /// a few new songs is far cheaper than re-reading thousands, and unlike
    /// a rescan it leaves every existing track (and so the play queue and
    /// playlists) exactly as it was.
    ///
    /// A path that is already in the library is refreshed in place, keeping
    /// its identity, play count and rating. Returns how many tracks are new.
    @discardableResult
    func indexFiles(rootID: UUID, relativePaths: [String]) async -> Int {
        guard let root = roots.first(where: { $0.id == rootID }),
              let base = FolderAccessManager.shared.resolve(root) else { return 0 }

        var fresh: [Track] = []
        var seen = Set<String>()
        var albumArtwork: [String: String] = [:]

        for relative in relativePaths where seen.insert(relative).inserted {
            let url = base.appendingPathComponent(relative)
            guard AudioFormats.isPlayable(url.pathExtension),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            guard var info = await MetadataReader.read(url: url, rootID: rootID,
                                                       relativePath: relative) else { continue }
            if info.track.duration < settings.minimumTrackSeconds { continue }

            let albumKey = info.track.albumKey
            if let known = albumArtwork[albumKey] {
                info.track.artworkKey = known
            } else if let data = info.artwork,
                      let key = ArtworkStore.shared.store(data, forAlbumKey: albumKey) {
                albumArtwork[albumKey] = key
                info.track.artworkKey = key
            } else if let key = tracks.first(where: { $0.albumKey == albumKey && $0.artworkKey != nil })?.artworkKey {
                // Another song of the same album already has a cover.
                albumArtwork[albumKey] = key
                info.track.artworkKey = key
            }
            applyOverrides(to: &info.track)
            fresh.append(info.track)
        }
        // The folder may have been removed from the library while the tags
        // were being read; its songs must not come back without it.
        guard !fresh.isEmpty, roots.contains(where: { $0.id == rootID }) else { return 0 }

        // One assignment to `tracks` so observers redraw once.
        var updated = tracks
        var added = 0
        for var track in fresh {
            if let idx = updated.firstIndex(where: { $0.rootID == rootID
                                                     && $0.relativePath == track.relativePath
                                                     && !$0.isCueTrack }) {
                let old = updated[idx]
                track.id = old.id
                track.dateAdded = old.dateAdded
                track.playCount = old.playCount
                track.lastPlayed = old.lastPlayed
                track.rating = old.rating
                updated[idx] = track
            } else {
                updated.append(track)
                added += 1
            }
        }
        tracks = updated
        if let idx = roots.firstIndex(where: { $0.id == rootID }) {
            roots[idx].trackCount = fileCount(inRoot: rootID)
        }
        rebuildIndex()
        reconcileDuplicates()
        save()
        return added
    }

    // MARK: - Scanning

    func rescanAll() async {
        for root in roots {
            await rescan(rootID: root.id)
        }
        save()
    }

    func rescan(rootID: UUID) async {
        guard let root = roots.first(where: { $0.id == rootID }),
              let url = FolderAccessManager.shared.resolve(root) else {
            scanStatus = "Cannot reach \(roots.first(where: { $0.id == rootID })?.displayName ?? "folder")"
            return
        }

        isScanning = true
        scanProgress = 0
        scanStatus = "Scanning \(root.displayName)…"
        await indexer.reset()

        let cfg = LibraryIndexer.IndexSettings(parseCueSheets: settings.parseCueSheets,
                                               importM3U: settings.importM3U,
                                               minimumSeconds: settings.minimumTrackSeconds)

        let result = await indexer.index(root: root, rootURL: url, settings: cfg) { progress in
            Task { @MainActor [weak self] in
                self?.scanProgress = progress.fraction
                self?.scanStatus = progress.currentPath
            }
        }

        // Done here, before anything is changed, so the duplicate check at
        // the end has nothing slow left to do.
        await warmSongKeys(for: result.tracks)

        // Preserve play counts / ratings across a rescan.
        var stats: [String: (Int, Date?, Int)] = [:]
        for t in tracks where t.rootID == rootID {
            stats[t.relativePath + "|" + Self.cueKey(t.cueStart)] = (t.playCount, t.lastPlayed, t.rating)
        }

        var merged = result.tracks
        for i in merged.indices {
            let key = merged[i].relativePath + "|" + Self.cueKey(merged[i].cueStart)
            if let s = stats[key] {
                merged[i].playCount = s.0
                merged[i].lastPlayed = s.1
                merged[i].rating = s.2
            }
            // Edits made in Sonora win over what the file says.
            applyOverrides(to: &merged[i])
        }

        tracks.removeAll { $0.rootID == rootID }
        // The scan found every file again, including copies that were hidden.
        hiddenTracks.removeAll { $0.rootID == rootID }
        tracks.append(contentsOf: merged)

        // Replace previously imported playlists from this root.
        let importedNames = Set(result.playlists.map(\.name))
        playlists.removeAll { $0.importedFrom != nil && importedNames.contains($0.name) }
        playlists.append(contentsOf: result.playlists)

        if let idx = roots.firstIndex(where: { $0.id == rootID }) {
            roots[idx].trackCount = merged.count
        }
        lastScanSkipped = result.skipped
        rebuildIndex()
        reconcileDuplicates()

        isScanning = false
        scanProgress = 1
        scanStatus = "\(merged.count) track\(merged.count == 1 ? "" : "s") in \(root.displayName)"
        save()
    }

    /// Whole-second cue offset as a merge key. `Int(Double)` traps on NaN,
    /// infinity or out-of-range values, which a malformed cue sheet can give.
    private static func cueKey(_ start: TimeInterval?) -> String {
        guard let start else { return "-1" }
        guard start.isFinite, abs(start) < 1e12 else { return "x" }
        return String(Int(start))
    }

    func cancelScan() {
        Task { await indexer.cancel() }
        isScanning = false
        scanStatus = "Scan cancelled"
    }

    // MARK: - Mutations

    /// Position of a track in `tracks`, verified. The index map is rebuilt
    /// after every structural change, but a stale entry must never become an
    /// out-of-range subscript (a crash) or silently edit the wrong track.
    private func liveIndex(of id: UUID) -> Int? {
        guard let idx = trackIndex[id], tracks.indices.contains(idx),
              tracks[idx].id == id else { return nil }
        return idx
    }

    func markPlayed(_ rawID: UUID) {
        // A hidden copy counts as a play of the song it is merged into.
        let id = keeperOfHidden[rawID] ?? rawID
        guard let idx = liveIndex(of: id) else { return }
        tracks[idx].playCount += 1
        tracks[idx].lastPlayed = Date()
        recentlyPlayedIDs.removeAll { $0 == id }
        recentlyPlayedIDs.insert(id, at: 0)
        if recentlyPlayedIDs.count > 100 { recentlyPlayedIDs.removeLast() }
        scheduleSave()
    }

    func setRating(_ rating: Int, for rawID: UUID) {
        let id = keeperOfHidden[rawID] ?? rawID
        guard let idx = liveIndex(of: id) else { return }
        tracks[idx].rating = max(0, min(5, rating))
        scheduleSave()
    }

    /// Points every track of an album at a newly found cover.
    ///
    /// Artwork is stored per album key, so one lookup covers the whole record;
    /// this is what makes the result visible in the library lists, which read
    /// `artworkKey` off the tracks rather than off the store.
    func setArtworkKey(_ key: String, forAlbumKey albumKey: String) {
        var changed = false
        for i in tracks.indices where tracks[i].albumKey == albumKey && tracks[i].artworkKey != key {
            // A cover the user picked (or removed) in the tag editor wins.
            if artworkOverrides[Self.tagOverrideKey(for: tracks[i])] != nil { continue }
            tracks[i].artworkKey = key
            changed = true
        }
        if changed { scheduleSave() }
    }

    func setMeasuredGain(_ gain: Float, peak: Float, for id: UUID) {
        if liveIndex(of: id) == nil, let h = hiddenIndex[id], hiddenTracks.indices.contains(h),
           hiddenTracks[h].id == id {
            // Measured while a hidden copy was playing: it belongs to that file.
            if hiddenTracks[h].replayGainTrack == nil { hiddenTracks[h].replayGainTrack = gain }
            if hiddenTracks[h].peakTrack == nil { hiddenTracks[h].peakTrack = peak }
            return
        }
        guard let idx = liveIndex(of: id) else { return }
        if tracks[idx].replayGainTrack == nil { tracks[idx].replayGainTrack = gain }
        if tracks[idx].peakTrack == nil { tracks[idx].peakTrack = peak }
        scheduleSave()
    }

    // MARK: - Tag editing

    /// Stable identity of a track's file across rescans (track IDs are
    /// regenerated on every scan, so they cannot key anything persistent).
    static func tagOverrideKey(for track: Track) -> String {
        "\(track.rootID?.uuidString ?? "file")|\(track.relativePath)|\(cueKey(track.cueStart))"
    }

    /// Whether `applyTagEdit` can write into this track's own file. Cue-sheet
    /// tracks share one file with their siblings, so they are library-only.
    static func canWriteTags(to track: Track) -> Bool {
        !track.isCueTrack && TagWriter.canWrite(fileExtension: track.fileExtension)
    }

    /// True when the user picked or removed this track's cover in the editor,
    /// so automatic artwork lookups should leave it alone.
    func hasArtworkOverride(_ track: Track) -> Bool {
        artworkOverrides[Self.tagOverrideKey(for: track)] != nil
    }

    /// Applies every set field of `tags` to `track`. Strings: "" clears.
    /// Numbers: 0 (or less) clears.
    static func apply(_ tags: TagSet, to track: inout Track) {
        if let v = tags.title { track.title = v }
        if let v = tags.artist { track.artist = v }
        if let v = tags.albumArtist { track.albumArtist = v }
        if let v = tags.album { track.album = v }
        if let v = tags.genre { track.genre = v }
        if let v = tags.composer { track.composer = v }
        if let v = tags.comment { track.comment = v }
        if let v = tags.lyrics {
            track.lyrics = v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : v
        }
        if let v = tags.year { track.year = v > 0 ? v : nil }
        if let v = tags.trackNumber { track.trackNumber = v > 0 ? v : nil }
        if let v = tags.trackTotal { track.trackTotal = v > 0 ? v : nil }
        if let v = tags.discNumber { track.discNumber = v > 0 ? v : nil }
    }

    /// Re-applies the user's edits on top of metadata just read from disk.
    private func applyOverrides(to track: inout Track) {
        let key = Self.tagOverrideKey(for: track)
        if let tags = tagOverrides[key] {
            Self.apply(tags, to: &track)
        }
        if let art = artworkOverrides[key] {
            if art.isEmpty {
                track.artworkKey = nil
            } else if ArtworkStore.shared.exists(key: art) {
                track.artworkKey = art
            } else {
                // iOS purged the cached cover; fall back to what the file has.
                artworkOverrides[key] = nil
                saveOverrides()
            }
        }
    }

    /// Edits tags for one or more tracks: updates the library immediately,
    /// remembers the edit so it survives rescans, and — when asked and the
    /// format allows — writes the tags into the music files off the main thread.
    func applyTagEdit(trackIDs: [UUID],
                      tags: TagSet,
                      artwork: ArtworkChange,
                      writeToFiles: Bool) async -> TagEditResult {
        var result = TagEditResult(written: 0, libraryOnly: 0, failures: [])

        var seen = Set<UUID>()
        // Editing a hidden copy (it can still be the one playing) edits the
        // song it is merged into.
        let ids = trackIDs.map { keeperOfHidden[$0] ?? $0 }.filter { seen.insert($0).inserted }
        guard !ids.isEmpty, !tags.isEmpty || artwork != .keep else { return result }

        // 1. Cover: stored under a fresh key so every view keyed on
        //    `artworkKey` reloads (a reused key would show the cached image).
        var artworkChange = artwork
        var newArtworkKey: String?
        if case .replace(let data) = artwork {
            let storeKey = "tag-edit|\(UUID().uuidString)"
            newArtworkKey = await Task.detached(priority: .userInitiated) { () -> String? in
                ArtworkStore.shared.store(data, forAlbumKey: storeKey)
            }.value
            if newArtworkKey == nil {
                result.failures.append(("Cover", "The picture couldn't be read, so the cover was left as it was."))
                artworkChange = .keep
            }
        }

        // 2. Library. One assignment to `tracks` so observers redraw once.
        let now = Date()
        var updated = tracks
        var edited: [Track] = []
        for id in ids {
            guard let idx = liveIndex(of: id), updated.indices.contains(idx) else { continue }
            var t = updated[idx]
            let key = Self.tagOverrideKey(for: t)
            if !tags.isEmpty {
                Self.apply(tags, to: &t)
                tagOverrides[key] = (tagOverrides[key] ?? TagSet()).merged(with: tags)
            }
            switch artworkChange {
            case .keep:
                break
            case .replace:
                if let newKey = newArtworkKey {
                    t.artworkKey = newKey
                    artworkOverrides[key] = newKey
                }
            case .remove:
                t.artworkKey = nil
                artworkOverrides[key] = ""
            }
            t.dateModified = now
            updated[idx] = t
            edited.append(t)
        }
        guard !edited.isEmpty else { return result }
        tracks = updated
        rebuildIndex()
        saveOverrides()
        save()
        // New tags can turn two songs into duplicates, or stop them being
        // ones. Checked when the edit is completely finished.
        defer {
            reconcileDuplicates()
            save()
        }
        let editedIDs = Set(edited.map(\.id))
        refreshPlayerIfNeeded(editedIDs)

        // 3. Files.
        var jobs: [TagWriteJob] = []
        for t in edited {
            guard writeToFiles, Self.canWriteTags(to: t) else {
                result.libraryOnly += 1
                continue
            }
            guard let fileURL = self.url(for: t) else {
                result.failures.append((t.fileName,
                                        "Sonora can't reach this file right now. The changes are saved in Sonora's library."))
                continue
            }
            let key = Self.tagOverrideKey(for: t)
            // Write the whole pending edit, including fields from an earlier
            // edit whose write failed, so dropping the override afterwards
            // loses nothing.
            jobs.append(TagWriteJob(trackID: t.id,
                                    key: key,
                                    name: t.fileName,
                                    url: fileURL,
                                    tags: tagOverrides[key] ?? tags))
        }
        guard !jobs.isEmpty else { return result }

        let jobsToRun = jobs
        let change = artworkChange
        let outcomes: [String?] = await Task.detached(priority: .userInitiated) { () -> [String?] in
            var out: [String?] = []
            out.reserveCapacity(jobsToRun.count)
            for job in jobsToRun {
                // Root folders keep their scope open for the whole launch;
                // this covers files whose own URL carries the scope.
                let scoped = job.url.startAccessingSecurityScopedResource()
                do {
                    try await TagWriter.write(job.tags, artwork: change, to: job.url)
                    out.append(nil)
                } catch {
                    out.append(error.localizedDescription)
                }
                if scoped { job.url.stopAccessingSecurityScopedResource() }
            }
            return out
        }.value

        for (i, job) in jobsToRun.enumerated() {
            let failure: String? = outcomes.indices.contains(i) ? outcomes[i] : "The write didn't finish."
            if let failure {
                result.failures.append((job.name, failure + " The changes are saved in Sonora's library."))
                continue
            }
            result.written += 1
            // The file now carries the truth.
            tagOverrides[job.key] = nil
            if let idx = liveIndex(of: job.trackID) {
                switch change {
                case .keep: break
                case .replace: tracks[idx].hasEmbeddedArtwork = true
                case .remove: tracks[idx].hasEmbeddedArtwork = false
                }
            }
        }
        saveOverrides()
        save()
        refreshPlayerIfNeeded(editedIDs)
        return result
    }

    private func refreshPlayerIfNeeded(_ ids: Set<UUID>) {
        guard let player = AppServices.player,
              let currentID = player.currentTrack?.id,
              ids.contains(currentID) else { return }
        player.refreshCurrentTrackFromLibrary()
    }

    // MARK: - Duplicates

    /// How many files a folder holds, counting copies hidden as duplicates.
    private func fileCount(inRoot rootID: UUID) -> Int {
        tracks.reduce(0) { $0 + ($1.rootID == rootID ? 1 : 0) }
            + hiddenTracks.reduce(0) { $0 + ($1.rootID == rootID ? 1 : 0) }
    }

    private func songKey(for track: Track) -> SongKey {
        let raw = DuplicateFinder.rawTags(of: track)
        if let known = songKeyCache[raw] { return known }
        if songKeyCache.count > 60_000 { songKeyCache.removeAll(keepingCapacity: true) }
        let made = DuplicateFinder.key(for: raw)
        songKeyCache[raw] = made
        return made
    }

    /// Works out the comparison keys for these songs away from the main
    /// thread and keeps them. `reconcileDuplicates` needs a key per song;
    /// with them ready it takes a few thousandths of a second even for a
    /// library of many thousands of songs, so the screen never stutters.
    private func warmSongKeys(for list: [Track]) async {
        var missing = Set<DuplicateFinder.RawTags>()
        for track in list {
            let raw = DuplicateFinder.rawTags(of: track)
            if songKeyCache[raw] == nil { missing.insert(raw) }
        }
        // A few hundred are quick enough to do on the spot.
        guard missing.count > 300 else { return }
        let todo = missing
        let made = await Task.detached(priority: .userInitiated) { () -> [DuplicateFinder.RawTags: SongKey] in
            var out: [DuplicateFinder.RawTags: SongKey] = [:]
            out.reserveCapacity(todo.count)
            for raw in todo { out[raw] = DuplicateFinder.key(for: raw) }
            return out
        }.value
        if songKeyCache.count + made.count > 60_000 { songKeyCache.removeAll(keepingCapacity: true) }
        songKeyCache.merge(made) { current, _ in current }
    }

    private func signature(of track: Track) -> String {
        DuplicateFinder.signature(songKey(for: track), duration: track.duration)
    }

    /// Looks at the whole library again and decides, from scratch, which
    /// songs are shown and which are hidden behind a better copy.
    ///
    /// The result depends only on the songs and on the user's remembered
    /// answers, so it is safe to call as often as needed: after a scan, a
    /// download, a tag edit, an answer. Nothing is ever deleted here.
    func reconcileDuplicates() {
        let rootIDs = Set(roots.map(\.id))
        let visibleFiles = Set(tracks.map { Self.tagOverrideKey(for: $0) })

        var all = tracks
        for copy in hiddenTracks {
            // Its folder left the library.
            if let root = copy.rootID, !rootIDs.contains(root) { continue }
            // A rescan found the same file again; the fresh entry replaces it.
            if visibleFiles.contains(Self.tagOverrideKey(for: copy)) { continue }
            all.append(copy)
        }

        var hide = Set<Int>()
        var keeperMap: [UUID: UUID] = [:]
        var groups: [MergedSongGroup] = []
        var questions: [DuplicateQuestion] = []

        if duplicateMemory.enabled, all.count > 1 {
            let keys = all.map { songKey(for: $0) }
            let result = DuplicateFinder.analyse(tracks: all, keys: keys, memory: duplicateMemory)
            for group in result.groups {
                guard let keep = group.first, all.indices.contains(keep) else { continue }
                var copies: [UUID] = []
                for other in group.dropFirst() where all.indices.contains(other) {
                    // Everything the user built up on a copy moves to the
                    // song that stays. Play counts are moved, not copied, so
                    // doing this again later adds nothing twice.
                    all[keep].playCount += all[other].playCount
                    all[other].playCount = 0
                    all[keep].rating = max(all[keep].rating, all[other].rating)
                    if let played = all[other].lastPlayed,
                       played > (all[keep].lastPlayed ?? .distantPast) {
                        all[keep].lastPlayed = played
                    }
                    if all[other].dateAdded < all[keep].dateAdded {
                        all[keep].dateAdded = all[other].dateAdded
                    }
                    if (all[keep].lyrics ?? "").isEmpty, let lyrics = all[other].lyrics, !lyrics.isEmpty {
                        all[keep].lyrics = lyrics
                    }
                    if all[keep].artworkKey == nil { all[keep].artworkKey = all[other].artworkKey }
                    hide.insert(other)
                    keeperMap[all[other].id] = all[keep].id
                    copies.append(all[other].id)
                }
                if !copies.isEmpty {
                    groups.append(MergedSongGroup(keeper: all[keep].id, copies: copies))
                }
            }
            questions = result.questions
        }

        var visible: [Track] = []
        var hidden: [Track] = []
        visible.reserveCapacity(all.count)
        for (i, track) in all.enumerated() {
            if hide.contains(i) { hidden.append(track) } else { visible.append(track) }
        }

        // Assigned only when something really changed, so the screens are
        // not redrawn for nothing.
        if visible != tracks { tracks = visible }
        let hiddenChanged = hidden != hiddenTracks
        if hiddenChanged { hiddenTracks = hidden }
        rebuildIndex()
        keeperOfHidden = keeperMap
        if groups != mergedGroups { mergedGroups = groups }
        if questions != duplicateQuestions { duplicateQuestions = questions }
        pointPlaylistsAtKeepers(keeperMap)
        if hiddenChanged { saveDuplicates() }
    }

    /// Playlists and "recently played" show the kept song instead of a
    /// hidden copy, and never the same song twice because of a merge.
    private func pointPlaylistsAtKeepers(_ map: [UUID: UUID]) {
        guard !map.isEmpty else { return }
        for i in playlists.indices where playlists[i].trackIDs.contains(where: { map[$0] != nil }) {
            var present = Set(playlists[i].trackIDs.filter { map[$0] == nil })
            var out: [UUID] = []
            out.reserveCapacity(playlists[i].trackIDs.count)
            for id in playlists[i].trackIDs {
                if let keeper = map[id] {
                    if present.insert(keeper).inserted { out.append(keeper) }
                } else {
                    out.append(id)
                }
            }
            playlists[i].trackIDs = out
        }
        if recentlyPlayedIDs.contains(where: { map[$0] != nil }) {
            var seen = Set<UUID>()
            recentlyPlayedIDs = recentlyPlayedIDs.compactMap { id -> UUID? in
                let target = map[id] ?? id
                return seen.insert(target).inserted ? target : nil
            }
        }
    }

    /// The song with this id together with every copy merged into it,
    /// the shown one first.
    func mergedCopies(of id: UUID) -> [Track] {
        let keeperID = keeperOfHidden[id] ?? id
        var out: [Track] = []
        if let keeper = track(id: keeperID) { out.append(keeper) }
        if let group = mergedGroups.first(where: { $0.keeper == keeperID }) {
            out.append(contentsOf: group.copies.compactMap { track(id: $0) })
        }
        if out.isEmpty, let only = track(id: id) { out = [only] }
        return out
    }

    /// Records the answer to a question and applies it straight away.
    /// With `forSimilar`, the same answer is used from now on for every
    /// pair Sonora would have asked about for the same reason.
    func answerDuplicate(_ question: DuplicateQuestion, _ answer: DuplicateAnswer, forSimilar: Bool) {
        duplicateMemory.pairs[question.id] = answer
        if forSimilar { duplicateMemory.rules[question.doubt.rawValue] = answer }
        saveDuplicates()
        reconcileDuplicates()
        save()
    }

    /// Takes one hidden copy out of its group and shows it as a song of its
    /// own again. Remembered, so it is not merged back.
    func separateMergedCopy(_ id: UUID) {
        guard let keeperID = keeperOfHidden[id], let copy = track(id: id) else { return }
        let mine = signature(of: copy)
        for other in mergedCopies(of: keeperID) where other.id != id {
            duplicateMemory.pairs[DuplicateFinder.pairKey(mine, signature(of: other))] = .separate
        }
        saveDuplicates()
        reconcileDuplicates()
        save()
    }

    func setMergeDuplicates(_ on: Bool) {
        guard duplicateMemory.enabled != on else { return }
        duplicateMemory.enabled = on
        saveDuplicates()
        reconcileDuplicates()
        save()
    }

    /// Forgets one "always do this" rule; those pairs are asked about again.
    func forgetDuplicateRule(_ doubt: DuplicateDoubt) {
        guard duplicateMemory.rules[doubt.rawValue] != nil else { return }
        duplicateMemory.rules[doubt.rawValue] = nil
        saveDuplicates()
        reconcileDuplicates()
        save()
    }

    /// Forgets every answer and rule. Clear duplicates are still merged;
    /// everything Sonora was unsure about is asked again.
    func forgetDuplicateAnswers() {
        duplicateMemory.pairs = [:]
        duplicateMemory.rules = [:]
        saveDuplicates()
        reconcileDuplicates()
        save()
    }

    // MARK: - Deleting songs

    /// True when the song was downloaded from Google Drive by Sonora.
    func isDriveTrack(_ track: Track) -> Bool {
        guard let rootID = track.rootID,
              let driveRoot = appFolderRoot(relativePath: GoogleDriveConfig.localFolderName) else { return false }
        return rootID == driveRoot.id
    }

    /// What deleting this song would touch, for the confirmation dialog.
    func deleteInfo(for id: UUID) -> SongDeleteInfo? {
        let copies = mergedCopies(of: id)
        guard let first = copies.first else { return nil }
        let deletable = copies.filter { !$0.isCueTrack }
        var folder = "Files"
        if let rootID = first.rootID, let root = roots.first(where: { $0.id == rootID }) {
            folder = root.displayName
        }
        return SongDeleteInfo(title: first.displayTitle,
                              fileName: first.fileName,
                              folderName: folder,
                              fileCount: deletable.count,
                              driveCount: deletable.filter { isDriveTrack($0) }.count,
                              isCueOnly: deletable.isEmpty)
    }

    /// Deletes the music files of these songs (and of every copy merged into
    /// them) and takes them out of the library, the playlists and the queue.
    ///
    /// With `fromDrive`, a song downloaded from Google Drive is moved to the
    /// Bin in Drive first; if that fails the copy on the iPhone is kept too,
    /// so nothing ends up half deleted. Without it, the song stays in Drive
    /// and sync is told not to bring it back.
    func deleteSongs(ids: [UUID], fromDrive: Bool) async -> SongDeleteReport {
        var report = SongDeleteReport()

        var seen = Set<UUID>()
        var targets: [Track] = []
        for id in ids {
            for copy in mergedCopies(of: id) where seen.insert(copy.id).inserted {
                targets.append(copy)
            }
        }
        let files = targets.filter { !$0.isCueTrack }
        if files.count < targets.count {
            report.problems.append("A song that is one part of a longer file can't be deleted on its own.")
        }
        guard !files.isEmpty else { return report }

        // Move the player off these songs before their files disappear.
        AppServices.player?.tracksWillBeDeleted(Set(files.map(\.id)))

        var removed: [Track] = []
        for track in files {
            let name = "“\(track.displayTitle)”"
            let isDrive = isDriveTrack(track)

            if isDrive, fromDrive {
                let drive = GoogleDriveManager.shared
                if drive.driveFileIDs(forLocalPath: track.relativePath).isEmpty {
                    report.problems.append("\(name): Sonora no longer knows which Google Drive file this was, so it is still in Drive.")
                } else {
                    do {
                        try await drive.moveToBin(localPath: track.relativePath)
                        report.movedToDriveBin += 1
                    } catch {
                        report.problems.append("\(name) wasn't deleted: Google Drive said no. \(DriveError.message(for: error))")
                        continue
                    }
                }
            }

            guard let fileURL = url(for: track) else {
                report.problems.append("\(name): Sonora can't reach this file right now.")
                continue
            }
            switch await FileRemover.remove(fileURL) {
            case .removed, .alreadyGone:
                removed.append(track)
                report.deleted += 1
                if isDrive {
                    GoogleDriveManager.shared.forgetDownload(localPath: track.relativePath,
                                                            keepOffThisPhone: !fromDrive)
                }
            case .failed(let message):
                report.problems.append("\(name): \(message)")
            }
        }

        forget(tracks: removed)
        if removed.contains(where: { isDriveTrack($0) }) {
            await GoogleDriveManager.shared.refreshStorage()
        }
        return report
    }

    /// Takes tracks out of everything the library keeps. Files are not touched.
    private func forget(tracks gone: [Track]) {
        guard !gone.isEmpty else { return }
        let ids = Set(gone.map(\.id))
        tracks.removeAll { ids.contains($0.id) }
        hiddenTracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices {
            playlists[i].trackIDs.removeAll { ids.contains($0) }
        }
        recentlyPlayedIDs.removeAll { ids.contains($0) }

        var overridesChanged = false
        for track in gone {
            let key = Self.tagOverrideKey(for: track)
            if tagOverrides.removeValue(forKey: key) != nil { overridesChanged = true }
            if artworkOverrides.removeValue(forKey: key) != nil { overridesChanged = true }
        }
        if overridesChanged { saveOverrides() }

        rebuildIndex()
        for i in roots.indices { roots[i].trackCount = fileCount(inRoot: roots[i].id) }
        reconcileDuplicates()
        saveDuplicates()
        save()
        // Anything the queue still holds that no longer exists.
        AppServices.player?.pruneQueue()
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named name: String, trackIDs: [UUID] = []) -> Playlist {
        let p = Playlist(name: name, trackIDs: trackIDs)
        playlists.append(p)
        save()
        return p
    }

    func addToPlaylist(_ playlistID: UUID, trackIDs: [UUID]) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].trackIDs.append(contentsOf: trackIDs)
        playlists[idx].dateModified = Date()
        save()
    }

    func removeFromPlaylist(_ playlistID: UUID, at rawOffsets: IndexSet) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        // `remove(atOffsets:)` traps on an out-of-range offset.
        let count = playlists[idx].trackIDs.count
        let offsets = IndexSet(rawOffsets.filter { $0 >= 0 && $0 < count })
        guard !offsets.isEmpty else { return }
        playlists[idx].trackIDs.remove(atOffsets: offsets)
        playlists[idx].dateModified = Date()
        save()
    }

    func movePlaylistItems(_ playlistID: UUID, from rawFrom: IndexSet, to rawTo: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        // `move(fromOffsets:toOffset:)` traps on out-of-range indices.
        let count = playlists[idx].trackIDs.count
        let from = IndexSet(rawFrom.filter { $0 >= 0 && $0 < count })
        guard !from.isEmpty else { return }
        let to = max(0, min(rawTo, count))
        playlists[idx].trackIDs.move(fromOffsets: from, toOffset: to)
        playlists[idx].dateModified = Date()
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
        playlists[idx].dateModified = Date()
        save()
    }

    // MARK: - Derived collections

    var albums: [AlbumGroup] {
        var buckets: [String: AlbumGroup] = [:]
        for t in tracks {
            let key = t.albumKey
            if var existing = buckets[key] {
                existing.trackIDs.append(t.id)
                existing.totalDuration += t.duration
                if existing.artworkKey == nil { existing.artworkKey = t.artworkKey }
                if existing.year == nil { existing.year = t.year }
                if !existing.isCompilation && existing.artist != t.displayArtist {
                    existing.isCompilation = true
                }
                buckets[key] = existing
            } else {
                buckets[key] = AlbumGroup(id: key,
                                          title: t.displayAlbum,
                                          artist: t.effectiveAlbumArtist,
                                          year: t.year,
                                          artworkKey: t.artworkKey,
                                          trackIDs: [t.id],
                                          totalDuration: t.duration,
                                          isCompilation: false)
            }
        }
        return buckets.values.sorted {
            if $0.artist.lowercased() == $1.artist.lowercased() {
                return ($0.year ?? 0, $0.title.lowercased()) < ($1.year ?? 0, $1.title.lowercased())
            }
            return $0.artist.lowercased() < $1.artist.lowercased()
        }
    }

    var artists: [ArtistGroup] {
        var buckets: [String: (name: String, ids: [UUID], albums: Set<String>, art: String?)] = [:]
        for t in tracks {
            let key = t.effectiveAlbumArtist.lowercased()
            var entry = buckets[key] ?? (t.effectiveAlbumArtist, [], [], nil)
            entry.ids.append(t.id)
            entry.albums.insert(t.displayAlbum.lowercased())
            if entry.art == nil { entry.art = t.artworkKey }
            buckets[key] = entry
        }
        return buckets.map { ArtistGroup(id: $0.key,
                                         name: $0.value.name,
                                         albumCount: $0.value.albums.count,
                                         trackIDs: $0.value.ids,
                                         artworkKey: $0.value.art) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var genres: [GenreGroup] {
        var buckets: [String: (name: String, ids: [UUID], art: String?)] = [:]
        for t in tracks {
            let name = t.genre.isEmpty ? "Unknown Genre" : t.genre
            let key = name.lowercased()
            var entry = buckets[key] ?? (name, [], nil)
            entry.ids.append(t.id)
            if entry.art == nil { entry.art = t.artworkKey }
            buckets[key] = entry
        }
        return buckets.map { GenreGroup(id: $0.key, name: $0.value.name,
                                        trackIDs: $0.value.ids, artworkKey: $0.value.art) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Builds the folder tree lazily; callers hold on to the returned root.
    func folderTree() -> FolderNode {
        let master = FolderNode(id: "__root__", name: "Library", rootID: nil, path: "")

        for root in roots {
            let node = FolderNode(id: root.id.uuidString, name: root.displayName, rootID: root.id, path: "")
            node.parent = master
            master.children.append(node)

            var index: [String: FolderNode] = ["": node]
            let rootTracks = tracks.filter { $0.rootID == root.id }
                                   .sorted { $0.relativePath.lowercased() < $1.relativePath.lowercased() }
            for t in rootTracks {
                let folder = t.relativeFolder
                let parent = ensureNode(path: folder, rootID: root.id, index: &index, base: node)
                parent.trackIDs.append(t.id)
            }
        }

        let loose = tracks.filter { $0.rootID == nil }
        if !loose.isEmpty {
            let node = FolderNode(id: "__imported__", name: "Imported Files", rootID: nil, path: "")
            node.trackIDs = loose.map(\.id)
            node.parent = master
            master.children.append(node)
        }
        return master
    }

    private func ensureNode(path: String,
                            rootID: UUID,
                            index: inout [String: FolderNode],
                            base: FolderNode) -> FolderNode {
        if let hit = index[path] { return hit }
        let parentPath = (path as NSString).deletingLastPathComponent
        let parent = ensureNode(path: parentPath, rootID: rootID, index: &index, base: base)
        let node = FolderNode(id: "\(rootID.uuidString)/\(path)",
                              name: (path as NSString).lastPathComponent,
                              rootID: rootID,
                              path: path)
        node.parent = parent
        parent.children.append(node)
        index[path] = node
        return node
    }

    // MARK: - Search

    func search(_ query: String, limit: Int = 200) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let terms = q.split(separator: " ").map(String.init)

        func score(_ t: Track) -> Int {
            let haystacks = [t.displayTitle.lowercased(), t.displayArtist.lowercased(),
                             t.displayAlbum.lowercased(), t.genre.lowercased(),
                             t.fileName.lowercased()]
            var total = 0
            for term in terms {
                var best = 0
                for (i, h) in haystacks.enumerated() {
                    if h == term { best = max(best, 100 - i * 5) }
                    else if h.hasPrefix(term) { best = max(best, 70 - i * 5) }
                    else if h.contains(term) { best = max(best, 40 - i * 5) }
                }
                if best == 0 { return 0 }
                total += best
            }
            return total
        }

        return tracks.map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Stats

    var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    var totalBytes: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var roots: [FolderRoot]
        var tracks: [Track]
        var playlists: [Playlist]
        var recentlyPlayed: [UUID]
        var version: Int = 1
    }

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SonoraLibrary.json")
    }

    private func rebuildIndex() {
        trackIndex.removeAll(keepingCapacity: true)
        for (i, t) in tracks.enumerated() { trackIndex[t.id] = i }
        hiddenIndex.removeAll(keepingCapacity: true)
        for (i, t) in hiddenTracks.enumerated() { hiddenIndex[t.id] = i }
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            rebuildIndex()
            return
        }
        roots = snapshot.roots
        tracks = snapshot.tracks
        playlists = snapshot.playlists
        recentlyPlayedIDs = snapshot.recentlyPlayed
        rebuildIndex()
        for root in roots { FolderAccessManager.shared.resolve(root) }
    }

    func save() {
        let snapshot = Snapshot(roots: roots, tracks: tracks,
                                playlists: playlists, recentlyPlayed: recentlyPlayedIDs)
        let url = storeURL
        // One serial queue: concurrent writers could otherwise land out of
        // order, and an older snapshot could overwrite a newer one (or
        // resurrect a library that was just erased).
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let saveQueue = DispatchQueue(label: "sonora.library.save", qos: .utility)

    // MARK: Tag override persistence

    /// Kept apart from the library snapshot so its format can never stop an
    /// existing library from decoding.
    private struct OverrideSnapshot: Codable {
        var tags: [String: TagSet]
        var artwork: [String: String]
    }

    private var overridesStoreURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("SonoraTagOverrides.json")
    }

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: overridesStoreURL),
              let snapshot = try? JSONDecoder().decode(OverrideSnapshot.self, from: data) else { return }
        tagOverrides = snapshot.tags
        artworkOverrides = snapshot.artwork
    }

    private func saveOverrides() {
        let snapshot = OverrideSnapshot(tags: tagOverrides, artwork: artworkOverrides)
        let url = overridesStoreURL
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Duplicate persistence

    /// Kept apart from the library snapshot, like the tag overrides, so it
    /// can never stop an existing library from loading.
    private struct DuplicateSnapshot: Codable {
        var memory: DuplicateMemory
        var hidden: [Track]
    }

    private var duplicatesStoreURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("SonoraDuplicates.json")
    }

    private func loadDuplicates() {
        guard let data = try? Data(contentsOf: duplicatesStoreURL),
              let snapshot = try? JSONDecoder().decode(DuplicateSnapshot.self, from: data) else { return }
        duplicateMemory = snapshot.memory
        let rootIDs = Set(roots.map(\.id))
        let shown = Set(tracks.map(\.id))
        hiddenTracks = snapshot.hidden.filter { copy in
            if shown.contains(copy.id) { return false }
            if let root = copy.rootID { return rootIDs.contains(root) }
            return true
        }
        rebuildIndex()
    }

    private func saveDuplicates() {
        let snapshot = DuplicateSnapshot(memory: duplicateMemory, hidden: hiddenTracks)
        let url = duplicatesStoreURL
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        // Rewriting the whole library index is not free; batch play counts and
        // ratings. The app also saves when it goes to the background.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
    }

    func wipeLibrary() {
        // A batched save still pending would write the old library back.
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if isScanning { cancelScan() }
        FolderAccessManager.shared.releaseAll()
        roots.removeAll(); tracks.removeAll(); playlists.removeAll(); recentlyPlayedIDs.removeAll()
        trackIndex.removeAll()
        // The answers about duplicates are kept: they are about songs, not
        // about this index, and apply again when the music is added back.
        hiddenTracks.removeAll(); hiddenIndex.removeAll(); keeperOfHidden.removeAll()
        mergedGroups = []; duplicateQuestions = []
        saveDuplicates()
        tagOverrides.removeAll(); artworkOverrides.removeAll()
        ArtworkStore.shared.clear()
        Task { await WaveformAnalyzer.shared.clearCache() }
        // Queued behind any save already in flight, so none can land after it.
        let url = storeURL
        let overridesURL = overridesStoreURL
        Self.saveQueue.async {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: overridesURL)
        }
    }
}

// MARK: - Tag edit results

/// What `MediaLibrary.applyTagEdit` did.
struct TagEditResult {
    /// Files whose tags were rewritten on disk.
    var written: Int
    /// Tracks edited in Sonora's library only (format can't be written, cue
    /// track, or "Save into the music file" was off).
    var libraryOnly: Int
    /// (file name, message) for every write that failed. Those edits are
    /// still kept in the library.
    var failures: [(String, String)]
}

// MARK: - Deleting songs

/// What a delete would touch. Shown before the user confirms.
struct SongDeleteInfo {
    var title: String
    var fileName: String
    /// Name of the library folder the shown copy lives in.
    var folderName: String
    /// Files that would be deleted (the song plus copies merged into it).
    var fileCount: Int
    /// How many of those were downloaded from Google Drive.
    var driveCount: Int
    /// True when there is nothing to delete: a cue-sheet track shares its
    /// file with the other songs of the album.
    var isCueOnly: Bool
}

/// What `MediaLibrary.deleteSongs` did.
struct SongDeleteReport {
    /// Files deleted from the iPhone.
    var deleted = 0
    /// Songs moved to the Bin in Google Drive.
    var movedToDriveBin = 0
    /// One sentence per thing that went wrong.
    var problems: [String] = []
}

/// One file write, handed to a background task.
private struct TagWriteJob {
    let trackID: UUID
    let key: String
    let name: String
    let url: URL
    let tags: TagSet
}
