//
//  LibraryIndexer.swift
//  Sonora
//
//  Walks a granted folder, reads tags for every audio file it finds and
//  reports progress back to the library. Runs off the main actor.
//

import Foundation
import AVFoundation

struct IndexResult {
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var skipped: [String] = []
    var scannedFileCount = 0
}

struct IndexProgress {
    var currentPath: String
    var processed: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(processed) / Double(total) : 0 }
}

actor LibraryIndexer {

    private var cancelled = false

    func cancel() { cancelled = true }
    func reset() { cancelled = false }

    /// Indexes a folder root.
    func index(root: FolderRoot,
               rootURL: URL,
               settings: IndexSettings,
               progress: @escaping @Sendable (IndexProgress) -> Void) async -> IndexResult {

        cancelled = false
        var result = IndexResult()

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: rootURL,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return result
        }

        // First pass: collect candidate URLs so we can report real progress.
        var audioURLs: [URL] = []
        var cueURLs: [URL] = []
        var playlistURLs: [URL] = []

        for case let url as URL in enumerator {
            if cancelled { return result }
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            if AudioFormats.isPlayable(ext) {
                audioURLs.append(url)
            } else if ext == AudioFormats.cueExtension, settings.parseCueSheets {
                cueURLs.append(url)
            } else if AudioFormats.playlistExtensions.contains(ext), settings.importM3U {
                playlistURLs.append(url)
            } else if AudioFormats.unsupportedButKnown.contains(ext) {
                result.skipped.append(url.lastPathComponent)
            }
        }

        result.scannedFileCount = audioURLs.count
        let rootPath = rootURL.standardizedFileURL.path
        var cueCoveredFiles = Set<String>()

        // Cue sheets first: they replace the single big file they point at.
        for cueURL in cueURLs {
            if cancelled { return result }
            guard let sheet = CueSheetParser.parse(contentsOf: cueURL) else { continue }
            let folder = cueURL.deletingLastPathComponent()
            guard let audioName = sheet.audioFileNames.first else { continue }
            let audioURL = folder.appendingPathComponent(audioName)
            guard fm.fileExists(atPath: audioURL.path) else { continue }

            let relative = Self.relativePath(of: audioURL, under: rootPath)
            guard let info = await MetadataReader.read(url: audioURL, rootID: root.id, relativePath: relative) else { continue }
            let totalDuration = info.track.duration

            var artKey: String?
            if let data = info.artwork {
                artKey = ArtworkStore.shared.store(data, forAlbumKey: "\(sheet.performer)|\(sheet.albumTitle)")
            }
            if artKey == nil {
                artKey = ArtworkStore.shared.importSidecarArtwork(in: folder,
                                                                  albumKey: "\(sheet.performer)|\(sheet.albumTitle)")
            }

            for entry in sheet.entries {
                var t = info.track
                t.id = UUID()
                t.title = entry.title.isEmpty ? "Track \(entry.number)" : entry.title
                t.artist = entry.performer.isEmpty ? sheet.performer : entry.performer
                t.albumArtist = sheet.performer
                t.album = sheet.albumTitle
                if !sheet.genre.isEmpty { t.genre = sheet.genre }
                if let y = Int(sheet.date.prefix(4)) { t.year = y }
                t.trackNumber = entry.number
                t.trackTotal = sheet.entries.count
                t.cueStart = entry.startTime
                t.cueEnd = entry.endTime ?? totalDuration
                t.duration = (entry.endTime ?? totalDuration) - entry.startTime
                t.artworkKey = artKey
                result.tracks.append(t)
            }
            cueCoveredFiles.insert(audioURL.standardizedFileURL.path)
        }

        // Second pass: individual audio files.
        var processed = 0
        var albumArtworkKeys: [String: String] = [:]
        var foldersChecked = Set<String>()

        for url in audioURLs {
            if cancelled { return result }
            processed += 1
            if cueCoveredFiles.contains(url.standardizedFileURL.path) { continue }

            let relative = Self.relativePath(of: url, under: rootPath)
            progress(IndexProgress(currentPath: relative, processed: processed, total: audioURLs.count))

            guard var info = await MetadataReader.read(url: url, rootID: root.id, relativePath: relative) else { continue }
            if info.track.duration < settings.minimumSeconds { continue }

            let albumKey = info.track.albumKey
            if let data = info.artwork {
                if let existing = albumArtworkKeys[albumKey] {
                    info.track.artworkKey = existing
                } else if let key = ArtworkStore.shared.store(data, forAlbumKey: albumKey) {
                    albumArtworkKeys[albumKey] = key
                    info.track.artworkKey = key
                }
            } else if let existing = albumArtworkKeys[albumKey] {
                info.track.artworkKey = existing
            } else {
                let folder = url.deletingLastPathComponent()
                let folderKey = folder.path + "|" + albumKey
                if !foldersChecked.contains(folderKey) {
                    foldersChecked.insert(folderKey)
                    if let key = ArtworkStore.shared.importSidecarArtwork(in: folder, albumKey: albumKey) {
                        albumArtworkKeys[albumKey] = key
                        info.track.artworkKey = key
                    }
                }
            }

            result.tracks.append(info.track)
        }

        // Playlists reference files we have now indexed.
        for playlistURL in playlistURLs {
            if cancelled { return result }
            let entries = M3UParser.parse(contentsOf: playlistURL)
            guard !entries.isEmpty else { continue }
            let base = playlistURL.deletingLastPathComponent()
            var ids: [UUID] = []
            for entry in entries {
                let resolved = entry.path.hasPrefix("/")
                    ? URL(fileURLWithPath: entry.path)
                    : base.appendingPathComponent(entry.path)
                let relative = Self.relativePath(of: resolved, under: rootPath)
                if let match = result.tracks.first(where: { $0.relativePath == relative }) {
                    ids.append(match.id)
                }
            }
            guard !ids.isEmpty else { continue }
            let name = playlistURL.deletingPathExtension().lastPathComponent
            result.playlists.append(Playlist(name: name,
                                             trackIDs: ids,
                                             importedFrom: Self.relativePath(of: playlistURL, under: rootPath)))
        }

        return result
    }

    struct IndexSettings {
        var parseCueSheets: Bool
        var importM3U: Bool
        var minimumSeconds: Double
    }

    static func relativePath(of url: URL, under rootPath: String) -> String {
        let full = url.standardizedFileURL.path
        if full.hasPrefix(rootPath) {
            var rel = String(full.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.lastPathComponent
    }
}
