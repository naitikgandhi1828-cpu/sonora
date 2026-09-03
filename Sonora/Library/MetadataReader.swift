//
//  MetadataReader.swift
//  Sonora
//
//  Pulls tags, technical details and embedded artwork out of an audio file
//  using AVFoundation's metadata APIs, with a filename fallback for files
//  that carry no tags at all.
//

import Foundation
import AVFoundation
import UIKit

enum MetadataReader {

    struct FileInfo {
        var track: Track
        var artwork: Data?
    }

    static func read(url: URL,
                     rootID: UUID?,
                     relativePath: String) async -> FileInfo? {

        let ext = url.pathExtension.lowercased()
        var track = Track()
        track.rootID = rootID
        track.relativePath = relativePath
        track.fileExtension = ext

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        track.fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        track.dateModified = (attrs?[.modificationDate] as? Date) ?? Date()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // Duration & technical properties
        let assetDuration = try? await asset.load(.duration)
        if let duration = assetDuration {
            track.duration = CMTimeGetSeconds(duration)
            if track.duration.isNaN || track.duration.isInfinite { track.duration = 0 }
        }

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if let audioTrack = audioTracks.first {
            let descriptions = (try? await audioTrack.load(.formatDescriptions)) ?? []
            for desc in descriptions {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    track.sampleRate = asbd.mSampleRate
                    track.channelCount = Int(asbd.mChannelsPerFrame)
                    if asbd.mBitsPerChannel > 0 { track.bitDepth = Int(asbd.mBitsPerChannel) }
                    track.codec = fourCC(asbd.mFormatID)
                }
            }
            let dataRate = try? await audioTrack.load(.estimatedDataRate)
            if let rate = dataRate, rate > 0 {
                track.bitrate = Int(rate / 1000)
            }
        }

        // Fall back to AVAudioFile when the asset gave us nothing useful.
        if track.sampleRate == 0, let f = try? AVAudioFile(forReading: url) {
            track.sampleRate = f.processingFormat.sampleRate
            track.channelCount = Int(f.processingFormat.channelCount)
            if track.duration == 0 {
                track.duration = Double(f.length) / max(1, f.processingFormat.sampleRate)
            }
        }

        // Tags
        var artworkData: Data?
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        var items: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        for format in formats {
            let more = (try? await asset.loadMetadata(for: format)) ?? []
            items.append(contentsOf: more)
        }

        for item in items {
            guard let value = (try? await item.load(.value)) ?? nil else { continue }
            let key = normalizedKey(for: item)
            let string = (value as? String) ?? (value as? NSNumber)?.stringValue

            switch key {
            case "title":       track.title = string ?? track.title
            case "artist":      track.artist = string ?? track.artist
            case "albumname":   track.album = string ?? track.album
            case "albumartist": track.albumArtist = string ?? track.albumArtist
            case "genre":       track.genre = string ?? track.genre
            case "composer":    track.composer = string ?? track.composer
            case "comment":     track.comment = string ?? track.comment
            case "year", "creationdate", "date", "recordingdate":
                if let s = string { track.year = parseYear(s) }
            case "tracknumber":
                if let s = string { let (n, t) = parsePair(s); track.trackNumber = n; track.trackTotal = t ?? track.trackTotal }
                else if let data = value as? Data { track.trackNumber = parseiTunesNumber(data) }
            case "discnumber":
                if let s = string { let (n, _) = parsePair(s); track.discNumber = n }
                else if let data = value as? Data { track.discNumber = parseiTunesNumber(data) }
            case "artwork":
                if let data = value as? Data { artworkData = data }
                else if let image = value as? UIImage { artworkData = image.jpegData(compressionQuality: 0.9) }
            case "replaygain_track_gain":
                track.replayGainTrack = parseGain(string)
            case "replaygain_album_gain":
                track.replayGainAlbum = parseGain(string)
            case "replaygain_track_peak":
                track.peakTrack = string.flatMap { Float($0) }
            default:
                break
            }
        }

        // Filename fallbacks: "01 - Artist - Title" style names.
        if track.title.isEmpty {
            let base = (relativePath as NSString).lastPathComponent
            let stem = (base as NSString).deletingPathExtension
            let parsed = parseFilename(stem)
            track.title = parsed.title
            if track.artist.isEmpty, let a = parsed.artist { track.artist = a }
            if track.trackNumber == nil { track.trackNumber = parsed.number }
        }
        if track.album.isEmpty {
            // Use the containing folder name as the album.
            let folder = (relativePath as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                track.album = (folder as NSString).lastPathComponent
            }
        }

        track.hasEmbeddedArtwork = artworkData != nil
        return FileInfo(track: track, artwork: artworkData)
    }

    // MARK: - Helpers

    private static func normalizedKey(for item: AVMetadataItem) -> String {
        if let common = item.commonKey?.rawValue {
            switch common {
            case "title": return "title"
            case "artist": return "artist"
            case "albumName": return "albumname"
            case "creationDate": return "creationdate"
            case "artwork": return "artwork"
            case "type": return "genre"
            default: break
            }
        }
        guard let raw = item.key else { return "" }
        var key = "\(raw)".lowercased()
        // ID3 and iTunes atoms
        switch key {
        case "tit2", "©nam": key = "title"
        case "tpe1", "©art": key = "artist"
        case "talb", "©alb": key = "albumname"
        case "tpe2", "aart": key = "albumartist"
        case "tcon", "©gen", "gnre": key = "genre"
        case "tcom", "©wrt": key = "composer"
        case "trck", "trkn": key = "tracknumber"
        case "tpos", "disk": key = "discnumber"
        case "tyer", "tdrc", "©day": key = "year"
        case "comm", "©cmt": key = "comment"
        case "apic", "covr": key = "artwork"
        default: break
        }
        // Vorbis / free-form identifiers arrive with prefixes.
        if let id = item.identifier?.rawValue.lowercased() {
            if id.contains("replaygain_track_gain") { return "replaygain_track_gain" }
            if id.contains("replaygain_album_gain") { return "replaygain_album_gain" }
            if id.contains("replaygain_track_peak") { return "replaygain_track_peak" }
            if id.contains("albumartist") || id.contains("album_artist") { return "albumartist" }
        }
        return key
    }

    private static func fourCC(_ code: AudioFormatID) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ]
        let s = String(bytes: bytes, encoding: .ascii) ?? ""
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func parseYear(_ s: String) -> Int? {
        let digits = s.prefix(while: { $0.isNumber })
        if digits.count >= 4 { return Int(digits.prefix(4)) }
        if let range = s.range(of: "\\d{4}", options: .regularExpression) {
            return Int(s[range])
        }
        return nil
    }

    private static func parsePair(_ s: String) -> (Int?, Int?) {
        let parts = s.split(separator: "/")
        let n = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let t = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (n, t)
    }

    private static func parseiTunesNumber(_ data: Data) -> Int? {
        // iTunes 'trkn' atoms are big-endian shorts: [0, index, total, 0]
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        return Int(bytes[3]) | (Int(bytes[2]) << 8)
    }

    private static func parseGain(_ s: String?) -> Float? {
        guard let s else { return nil }
        let cleaned = s.replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
                       .trimmingCharacters(in: .whitespaces)
        return Float(cleaned)
    }

    struct ParsedFilename {
        var number: Int?
        var artist: String?
        var title: String
    }

    static func parseFilename(_ stem: String) -> ParsedFilename {
        var working = stem.replacingOccurrences(of: "_", with: " ")
        var number: Int?

        // Leading track number: "01 ", "01. ", "01 - "
        if let match = working.range(of: "^\\s*(\\d{1,3})\\s*[-.)]?\\s+", options: .regularExpression) {
            let digits = working[match].trimmingCharacters(in: CharacterSet(charactersIn: " -.)"))
            number = Int(digits)
            working.removeSubrange(match)
        }

        let separators = [" - ", " – ", " — "]
        for sep in separators {
            if let r = working.range(of: sep) {
                let left = String(working[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let right = String(working[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty && !right.isEmpty {
                    return ParsedFilename(number: number, artist: left, title: right)
                }
            }
        }
        return ParsedFilename(number: number, artist: nil,
                              title: working.trimmingCharacters(in: .whitespaces))
    }
}
