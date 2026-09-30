//
//  TagModel.swift
//  Sonora
//
//  Shared types for Sonora's tag editor: the set of editable fields, the
//  errors a write can raise, and the front door that routes a write to the
//  right format-specific writer.
//
//  Format writers (each in its own file in this folder):
//    • ID3TagWriter   — MP3 (ID3v2.3 tag rewritten at the start of the file)
//    • FLACTagWriter  — FLAC (VORBIS_COMMENT and PICTURE metadata blocks)
//    • MP4TagWriter   — M4A / MP4 / ALAC (iTunes metadata via AVFoundation)
//  Anything else (WAV, AIFF, CAF, …) is edited in Sonora's library only.
//

import Foundation

/// Every tag field Sonora can edit. `nil` means "leave this field as it is"
/// (used by batch edits where the selected songs disagree); an empty string
/// means "clear this field".
struct TagSet: Codable, Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var genre: String?
    var composer: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var comment: String?
    var lyrics: String?

    /// True when no field would change anything.
    var isEmpty: Bool {
        title == nil && artist == nil && albumArtist == nil && album == nil
            && genre == nil && composer == nil && year == nil
            && trackNumber == nil && trackTotal == nil && discNumber == nil
            && comment == nil && lyrics == nil
    }

    /// Fields from `other` win wherever they are set.
    func merged(with other: TagSet) -> TagSet {
        TagSet(title: other.title ?? title,
               artist: other.artist ?? artist,
               albumArtist: other.albumArtist ?? albumArtist,
               album: other.album ?? album,
               genre: other.genre ?? genre,
               composer: other.composer ?? composer,
               year: other.year ?? year,
               trackNumber: other.trackNumber ?? trackNumber,
               trackTotal: other.trackTotal ?? trackTotal,
               discNumber: other.discNumber ?? discNumber,
               comment: other.comment ?? comment,
               lyrics: other.lyrics ?? lyrics)
    }
}

/// What to do with the embedded cover when writing.
enum ArtworkChange: Equatable {
    /// Leave whatever cover the file has.
    case keep
    /// Replace it with this JPEG or PNG data.
    case replace(Data)
    /// Remove the embedded cover.
    case remove
}

enum TagWriteError: LocalizedError {
    case unsupportedFormat(String)
    case unreadable(String)
    case malformed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Sonora can't write tags into .\(ext) files. The changes are saved in Sonora's library instead."
        case .unreadable(let why):
            return "Couldn't read the file: \(why)"
        case .malformed(let why):
            return "The file's existing tags look damaged: \(why)"
        case .writeFailed(let why):
            return "Couldn't save the file: \(why)"
        }
    }
}

/// Front door for writing tags into audio files.
enum TagWriter {

    /// File extensions whose tags Sonora can write in place.
    static func canWrite(fileExtension ext: String) -> Bool {
        switch ext.lowercased() {
        case "mp3", "flac", "m4a", "mp4", "aac", "alac", "m4b": return true
        default: return false
        }
    }

    /// Writes `tags` (fields that are `nil` are left untouched) and the
    /// artwork change into the file at `url`, replacing it atomically.
    ///
    /// The caller must already hold security-scoped access to `url` (or its
    /// folder). Never called on the main thread.
    static func write(_ tags: TagSet, artwork: ArtworkChange, to url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3":
            try ID3TagWriter.write(tags, artwork: artwork, to: url)
        case "flac":
            try FLACTagWriter.write(tags, artwork: artwork, to: url)
        case "m4a", "mp4", "aac", "alac", "m4b":
            try await MP4TagWriter.write(tags, artwork: artwork, to: url)
        default:
            throw TagWriteError.unsupportedFormat(ext)
        }
    }

    /// Replaces the file at `url` with `data`, keeping the original if
    /// anything goes wrong. Writes a sibling temp file first so a crash or a
    /// full disk can never leave a half-written song behind.
    static func replaceFile(at url: URL, with data: Data) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".sonora-tagtmp-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try data.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagWriteError.writeFailed(error.localizedDescription)
        }
    }
}
