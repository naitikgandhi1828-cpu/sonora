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
    }

    // MARK: - Lookup

    func track(id: UUID) -> Track? {
        guard let idx = liveIndex(of: id) else { return nil }
        return tracks[idx]
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
            roots[idx].trackCount = tracks.reduce(0) { $0 + ($1.rootID == rootID ? 1 : 0) }
        }
        rebuildIndex()
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

    func markPlayed(_ id: UUID) {
        guard let idx = liveIndex(of: id) else { return }
        tracks[idx].playCount += 1
        tracks[idx].lastPlayed = Date()
        recentlyPlayedIDs.removeAll { $0 == id }
        recentlyPlayedIDs.insert(id, at: 0)
        if recentlyPlayedIDs.count > 100 { recentlyPlayedIDs.removeLast() }
        scheduleSave()
    }

    func setRating(_ rating: Int, for id: UUID) {
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
        let ids = trackIDs.filter { seen.insert($0).inserted }
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

/// One file write, handed to a background task.
private struct TagWriteJob {
    let trackID: UUID
    let key: String
    let name: String
    let url: URL
    let tags: TagSet
}
