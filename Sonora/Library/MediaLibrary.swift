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

    // MARK: Init

    init(settings: AppSettings) {
        self.settings = settings
        load()
    }

    // MARK: - Lookup

    func track(id: UUID) -> Track? {
        guard let idx = trackIndex[id], idx < tracks.count else { return nil }
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
            tracks.append(info.track)
            added += 1
        }
        if added > 0 {
            rebuildIndex()
            save()
        }
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
            stats[t.relativePath + "|" + String(Int(t.cueStart ?? -1))] = (t.playCount, t.lastPlayed, t.rating)
        }

        var merged = result.tracks
        for i in merged.indices {
            let key = merged[i].relativePath + "|" + String(Int(merged[i].cueStart ?? -1))
            if let s = stats[key] {
                merged[i].playCount = s.0
                merged[i].lastPlayed = s.1
                merged[i].rating = s.2
            }
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

    func cancelScan() {
        Task { await indexer.cancel() }
        isScanning = false
        scanStatus = "Scan cancelled"
    }

    // MARK: - Mutations

    func markPlayed(_ id: UUID) {
        guard let idx = trackIndex[id] else { return }
        tracks[idx].playCount += 1
        tracks[idx].lastPlayed = Date()
        recentlyPlayedIDs.removeAll { $0 == id }
        recentlyPlayedIDs.insert(id, at: 0)
        if recentlyPlayedIDs.count > 100 { recentlyPlayedIDs.removeLast() }
        scheduleSave()
    }

    func setRating(_ rating: Int, for id: UUID) {
        guard let idx = trackIndex[id] else { return }
        tracks[idx].rating = max(0, min(5, rating))
        scheduleSave()
    }

    func setMeasuredGain(_ gain: Float, peak: Float, for id: UUID) {
        guard let idx = trackIndex[id] else { return }
        if tracks[idx].replayGainTrack == nil { tracks[idx].replayGainTrack = gain }
        if tracks[idx].peakTrack == nil { tracks[idx].peakTrack = peak }
        scheduleSave()
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

    func removeFromPlaylist(_ playlistID: UUID, at offsets: IndexSet) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].trackIDs.remove(atOffsets: offsets)
        playlists[idx].dateModified = Date()
        save()
    }

    func movePlaylistItems(_ playlistID: UUID, from: IndexSet, to: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
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
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func wipeLibrary() {
        FolderAccessManager.shared.releaseAll()
        roots.removeAll(); tracks.removeAll(); playlists.removeAll(); recentlyPlayedIDs.removeAll()
        trackIndex.removeAll()
        ArtworkStore.shared.clear()
        Task { await WaveformAnalyzer.shared.clearCache() }
        try? FileManager.default.removeItem(at: storeURL)
    }
}
