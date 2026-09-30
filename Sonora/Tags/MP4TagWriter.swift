//
//  MP4TagWriter.swift
//  Sonora
//
//  Writes iTunes-style metadata into MPEG-4 audio (M4A / MP4 / ALAC / M4B /
//  AAC-in-MP4) by re-muxing the file with a passthrough AVAssetExportSession.
//  The audio samples are copied untouched; only the container is rewritten.
//
//  Notes:
//  • Raw ADTS ".aac" files (not MPEG-4 containers) are refused: exporting
//    them would silently turn the file into an M4A behind a .aac name.
//  • ".m4b" files are written with the M4A file type (AVFoundation has no
//    audiobook file type).
//

import Foundation
import AVFoundation
import CoreMedia

enum MP4TagWriter {

    static func write(_ tags: TagSet, artwork: ArtworkChange, to url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        guard isMPEG4Container(url) else {
            throw TagWriteError.unsupportedFormat(ext)
        }

        let asset = AVURLAsset(url: url)
        let existing: [AVMetadataItem]
        do {
            existing = try await asset.load(.metadata)
        } catch {
            throw TagWriteError.unreadable(error.localizedDescription)
        }

        // Existing track/disc totals survive a number-only edit.
        let oldTrack = await numberPair(for: .iTunesMetadataTrackNumber, in: existing)
        let oldDisc = await numberPair(for: .iTunesMetadataDiscNumber, in: existing)

        // 1. Work out which existing items the edit replaces.
        var removeIdentifiers = Set<AVMetadataIdentifier>()
        var removeCommonKeys = Set<AVMetadataKey>()
        var newItems: [AVMetadataItem] = []

        func text(_ value: String?, _ identifier: AVMetadataIdentifier,
                  alsoRemove: [AVMetadataIdentifier] = [], commonKey: AVMetadataKey? = nil) {
            guard let value = value else { return }
            removeIdentifiers.insert(identifier)
            for other in alsoRemove { removeIdentifiers.insert(other) }
            if let key = commonKey { removeCommonKeys.insert(key) }
            if !value.isEmpty {
                newItems.append(makeItem(identifier, value: value as NSString))
            }
        }

        text(tags.title, .iTunesMetadataSongName, commonKey: .commonKeyTitle)
        text(tags.artist, .iTunesMetadataArtist, commonKey: .commonKeyArtist)
        text(tags.albumArtist, .iTunesMetadataAlbumArtist)
        text(tags.album, .iTunesMetadataAlbum, commonKey: .commonKeyAlbumName)
        text(tags.genre, .iTunesMetadataUserGenre, alsoRemove: [.iTunesMetadataPredefinedGenre])
        text(tags.composer, .iTunesMetadataComposer)
        if let year = tags.year {
            text(year > 0 ? String(year) : "", .iTunesMetadataReleaseDate, commonKey: .commonKeyCreationDate)
        }
        text(tags.comment, .iTunesMetadataUserComment)
        text(tags.lyrics, .iTunesMetadataLyrics)

        // trkn: 8 bytes [0,0, number(16), total(16), 0,0]; disk: 6 bytes [0,0, number(16), total(16)].
        if tags.trackNumber != nil || tags.trackTotal != nil {
            removeIdentifiers.insert(.iTunesMetadataTrackNumber)
            let number = tags.trackNumber ?? oldTrack.number
            let total = tags.trackTotal ?? oldTrack.total
            if number > 0 || total > 0 {
                var data = Data([0, 0])
                data.append(contentsOf: bigEndian16(number))
                data.append(contentsOf: bigEndian16(total))
                data.append(contentsOf: [0, 0])
                newItems.append(makeItem(.iTunesMetadataTrackNumber, value: data as NSData,
                                         dataType: kCMMetadataBaseDataType_RawData as String))
            }
        }
        if let disc = tags.discNumber {
            removeIdentifiers.insert(.iTunesMetadataDiscNumber)
            if disc > 0 {
                var data = Data([0, 0])
                data.append(contentsOf: bigEndian16(disc))
                data.append(contentsOf: bigEndian16(oldDisc.total))
                newItems.append(makeItem(.iTunesMetadataDiscNumber, value: data as NSData,
                                         dataType: kCMMetadataBaseDataType_RawData as String))
            }
        }

        switch artwork {
        case .keep:
            break
        case .remove:
            removeIdentifiers.insert(.iTunesMetadataCoverArt)
            removeCommonKeys.insert(.commonKeyArtwork)
        case .replace(let image):
            removeIdentifiers.insert(.iTunesMetadataCoverArt)
            removeCommonKeys.insert(.commonKeyArtwork)
            let dataType: String
            if image.count >= 3, image[image.startIndex] == 0xFF,
               image[image.startIndex + 1] == 0xD8, image[image.startIndex + 2] == 0xFF {
                dataType = kCMMetadataBaseDataType_JPEG as String
            } else if image.count >= 8,
                      [UInt8](image.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
                dataType = kCMMetadataBaseDataType_PNG as String
            } else {
                throw TagWriteError.writeFailed("the artwork must be a JPEG or PNG image")
            }
            newItems.append(makeItem(.iTunesMetadataCoverArt, value: image as NSData, dataType: dataType))
        }

        let kept = existing.filter { item in
            if let identifier = item.identifier, removeIdentifiers.contains(identifier) { return false }
            if let key = item.commonKey, removeCommonKeys.contains(key) { return false }
            return true
        }
        let metadata: [AVMetadataItem] = kept + newItems

        // 2. Re-mux into a sibling temp file.
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TagWriteError.unsupportedFormat(ext)
        }
        let fileType: AVFileType = ext == "mp4" ? .mp4 : .m4a
        guard session.supportedFileTypes.contains(fileType) else {
            throw TagWriteError.unsupportedFormat(ext)
        }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".sonora-tagtmp-\(UUID().uuidString).\(ext == "mp4" ? "mp4" : "m4a")")
        session.outputURL = temp
        session.outputFileType = fileType
        session.metadata = metadata
        session.shouldOptimizeForNetworkUse = false

        await session.export()

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            let reason = session.error?.localizedDescription ?? "export did not complete"
            throw TagWriteError.writeFailed(reason)
        }

        // 3. Swap it in.
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagWriteError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func makeItem(_ identifier: AVMetadataIdentifier,
                                 value: NSCopying & NSObjectProtocol,
                                 dataType: String? = nil) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        if let dataType = dataType {
            item.dataType = dataType
        }
        return item
    }

    /// Big-endian 16-bit value, clamped to 0...65535.
    private static func bigEndian16(_ value: Int) -> [UInt8] {
        let clamped = UInt16(clamping: max(0, value))
        return [UInt8(clamped >> 8), UInt8(clamped & 0x00FF)]
    }

    /// Number and total from an existing trkn / disk item (0 when absent).
    private static func numberPair(for identifier: AVMetadataIdentifier,
                                   in items: [AVMetadataItem]) async -> (number: Int, total: Int) {
        guard let item = items.first(where: { $0.identifier == identifier }) else { return (0, 0) }
        let loaded: Data? = try? await item.load(.dataValue)
        guard let data = loaded, data.count >= 6 else { return (0, 0) }
        let bytes = [UInt8](data)
        let number = Int(bytes[2]) << 8 | Int(bytes[3])
        let total = Int(bytes[4]) << 8 | Int(bytes[5])
        return (number, total)
    }

    /// True when the file starts with an ISO base media "ftyp" box.
    private static func isMPEG4Container(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 8 else { return false }
        let bytes = [UInt8](head)
        return bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 // "ftyp"
    }
}
