//
//  Models.swift
//  Sonora
//
//  Core data model for the music library.
//

import Foundation

// MARK: - Folder roots

/// A user-granted folder (from the Files app) that Sonora indexes.
/// Access is persisted with a security-scoped bookmark.
struct FolderRoot: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var bookmark: Data
    var dateAdded: Date = Date()
    var trackCount: Int = 0
    /// Last known absolute path, used only for display and diagnostics.
    var lastKnownPath: String = ""
}

// MARK: - Track

struct Track: Identifiable, Codable, Hashable {

    var id: UUID = UUID()

    /// Root this track was discovered under. `nil` for single files
    /// imported directly (those carry their own `standaloneBookmark`).
    var rootID: UUID?
    /// Path relative to the root folder, e.g. "Pink Moon/01 Track.flac".
    var relativePath: String = ""
    /// Bookmark for tracks that live outside any indexed root.
    var standaloneBookmark: Data?

    // Tags
    var title: String = ""
    var artist: String = ""
    var albumArtist: String = ""
    var album: String = ""
    var genre: String = ""
    var composer: String = ""
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var comment: String = ""

    // Technical
    var duration: TimeInterval = 0
    var sampleRate: Double = 0
    var channelCount: Int = 2
    var bitDepth: Int?
    var bitrate: Int?          // kbps
    var fileSize: Int64 = 0
    var fileExtension: String = ""
    var codec: String = ""

    // ReplayGain (read from tags where present, otherwise measured)
    var replayGainTrack: Float?
    var replayGainAlbum: Float?
    var peakTrack: Float?

    // Virtual track carved out of a single file by a .cue sheet
    var cueStart: TimeInterval?
    var cueEnd: TimeInterval?
    var isCueTrack: Bool { cueStart != nil }

    // Library bookkeeping
    var dateAdded: Date = Date()
    var dateModified: Date = Date()
    var playCount: Int = 0
    var lastPlayed: Date?
    var rating: Int = 0            // 0...5
    var artworkKey: String?        // file name inside the artwork cache
    var hasEmbeddedArtwork: Bool = false

    // MARK: Derived

    var displayTitle: String {
        title.isEmpty ? (fileName as NSString).deletingPathExtension : title
    }

    var displayArtist: String {
        if !artist.isEmpty { return artist }
        if !albumArtist.isEmpty { return albumArtist }
        return "Unknown Artist"
    }

    var displayAlbum: String {
        album.isEmpty ? "Unknown Album" : album
    }

    var effectiveAlbumArtist: String {
        if !albumArtist.isEmpty { return albumArtist }
        if !artist.isEmpty { return artist }
        return "Unknown Artist"
    }

    var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    /// Parent directory relative to the root, "" when at the root itself.
    var relativeFolder: String {
        let d = (relativePath as NSString).deletingLastPathComponent
        return d
    }

    var albumKey: String {
        "\(effectiveAlbumArtist.lowercased())|\(displayAlbum.lowercased())"
    }

    var qualityBadge: String {
        var parts: [String] = [fileExtension.uppercased()]
        if let bd = bitDepth, sampleRate > 0 {
            parts.append("\(bd)/\(Int(sampleRate / 1000))k")
        } else if sampleRate > 0 {
            parts.append("\(Int(sampleRate / 1000))k")
        }
        if let br = bitrate, br > 0, bitDepth == nil {
            parts.append("\(br)kbps")
        }
        return parts.joined(separator: " · ")
    }

    var isHiRes: Bool {
        sampleRate >= 88_200 || (bitDepth ?? 16) > 16
    }
}

// MARK: - Aggregates (computed, not persisted)

struct AlbumGroup: Identifiable, Hashable {
    var id: String              // albumKey
    var title: String
    var artist: String
    var year: Int?
    var artworkKey: String?
    var trackIDs: [UUID]
    var totalDuration: TimeInterval
    var isCompilation: Bool
}

struct ArtistGroup: Identifiable, Hashable {
    var id: String              // lowercased name
    var name: String
    var albumCount: Int
    var trackIDs: [UUID]
    var artworkKey: String?
}

struct GenreGroup: Identifiable, Hashable {
    var id: String
    var name: String
    var trackIDs: [UUID]
    var artworkKey: String?
}

/// A node in the folder tree built from track relative paths.
final class FolderNode: Identifiable, Hashable {
    let id: String              // "rootID/relative/path"
    let name: String
    let rootID: UUID?
    let path: String            // relative path, "" for root
    var children: [FolderNode] = []
    var trackIDs: [UUID] = []
    weak var parent: FolderNode?

    init(id: String, name: String, rootID: UUID?, path: String) {
        self.id = id
        self.name = name
        self.rootID = rootID
        self.path = path
    }

    var totalTrackCount: Int {
        trackIDs.count + children.reduce(0) { $0 + $1.totalTrackCount }
    }

    static func == (l: FolderNode, r: FolderNode) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Playlists

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var dateCreated: Date = Date()
    var dateModified: Date = Date()
    /// Set when the playlist was imported from an .m3u file on disk.
    var importedFrom: String?
}

// MARK: - Sorting

enum TrackSort: String, CaseIterable, Codable, Identifiable {
    case title, artist, album, dateAdded, duration, trackNumber, fileName, playCount, rating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .dateAdded: return "Date Added"
        case .duration: return "Duration"
        case .trackNumber: return "Track #"
        case .fileName: return "File Name"
        case .playCount: return "Play Count"
        case .rating: return "Rating"
        }
    }

    func comparator(ascending: Bool) -> (Track, Track) -> Bool {
        let asc = ascending
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Bool { asc ? a < b : a > b }
        switch self {
        case .title:       return { cmp($0.displayTitle.lowercased(), $1.displayTitle.lowercased()) }
        case .artist:      return { cmp($0.displayArtist.lowercased(), $1.displayArtist.lowercased()) }
        case .album:       return { cmp($0.displayAlbum.lowercased(), $1.displayAlbum.lowercased()) }
        case .dateAdded:   return { cmp($0.dateAdded, $1.dateAdded) }
        case .duration:    return { cmp($0.duration, $1.duration) }
        case .fileName:    return { cmp($0.fileName.lowercased(), $1.fileName.lowercased()) }
        case .playCount:   return { cmp($0.playCount, $1.playCount) }
        case .rating:      return { cmp($0.rating, $1.rating) }
        case .trackNumber:
            return {
                let a = ($0.discNumber ?? 1) * 1000 + ($0.trackNumber ?? 0)
                let b = ($1.discNumber ?? 1) * 1000 + ($1.trackNumber ?? 0)
                if a == b { return cmp($0.displayTitle.lowercased(), $1.displayTitle.lowercased()) }
                return cmp(a, b)
            }
        }
    }
}

// MARK: - Supported formats

enum AudioFormats {
    /// Containers AVFoundation can decode on iOS.
    static let supported: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "aif", "aiff", "aifc", "wav", "wave",
        "caf", "flac", "alac", "mp4", "m4r", "au", "snd", "amr", "ac3", "eac3"
    ]
    /// Extensions we index but cannot decode without an external decoder.
    static let unsupportedButKnown: Set<String> = [
        "ogg", "opus", "wma", "ape", "wv", "dsf", "dff", "mpc", "tta", "tak"
    ]
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]
    static let cueExtension = "cue"

    static func isPlayable(_ ext: String) -> Bool {
        supported.contains(ext.lowercased())
    }
}
