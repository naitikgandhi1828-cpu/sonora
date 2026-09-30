//
//  FLACTagWriter.swift
//  Sonora
//
//  Rewrites a FLAC file's metadata blocks:
//    STREAMINFO, VORBIS_COMMENT (rebuilt), new PICTURE (if any), every other
//    kept block in its original order, then one 1 KB PADDING block.
//  The audio frames after the metadata are copied verbatim.
//
//  Vorbis comment fields not edited by Sonora (ReplayGain, MusicBrainz ids,
//  …) are preserved byte for byte, as is the vendor string.
//

import Foundation
import ImageIO

enum FLACTagWriter {

    private static let paddingSize = 1024
    private static let maxBlockLength = 0xFF_FFFF

    private enum BlockType {
        static let streamInfo: UInt8 = 0
        static let padding: UInt8 = 1
        static let vorbisComment: UInt8 = 4
        static let picture: UInt8 = 6
    }

    private struct Block {
        var type: UInt8
        /// Block content without its 4-byte header (copied, 0-indexed).
        var body: Data
    }

    // MARK: - Entry point

    static func write(_ tags: TagSet, artwork: ArtworkChange, to url: URL) throws {
        let file: Data
        do {
            file = try Data(contentsOf: url)
        } catch {
            throw TagWriteError.unreadable(error.localizedDescription)
        }

        // Some taggers prepend an ID3v2 tag to FLAC files; skip (and drop) it.
        let flacStart = try leadingID3Size(file)

        guard file.count >= flacStart + 4,
              byte(file, flacStart) == 0x66, byte(file, flacStart + 1) == 0x4C,
              byte(file, flacStart + 2) == 0x61, byte(file, flacStart + 3) == 0x43 else { // "fLaC"
            throw TagWriteError.malformed("not a FLAC file (missing fLaC marker)")
        }

        // 1. Parse the metadata blocks.
        var blocks: [Block] = []
        var pos = flacStart + 4
        var sawLast = false
        while !sawLast {
            guard pos + 4 <= file.count else {
                throw TagWriteError.malformed("metadata ends unexpectedly")
            }
            let header = byte(file, pos)
            sawLast = (header & 0x80) != 0
            let type = header & 0x7F
            guard type != 127 else {
                throw TagWriteError.malformed("invalid metadata block type")
            }
            let length = Int(byte(file, pos + 1)) << 16 | Int(byte(file, pos + 2)) << 8 | Int(byte(file, pos + 3))
            let bodyStart = pos + 4
            guard length <= file.count - bodyStart else {
                throw TagWriteError.malformed("metadata block overruns the file")
            }
            let body = file.subdata(in: (file.startIndex + bodyStart)..<(file.startIndex + bodyStart + length))
            blocks.append(Block(type: type, body: body))
            pos = bodyStart + length
        }
        let audioStart = pos

        guard let first = blocks.first, first.type == BlockType.streamInfo else {
            throw TagWriteError.malformed("STREAMINFO is not the first metadata block")
        }

        // 2. Existing Vorbis comment (first one wins; duplicates are dropped).
        var vendor = Data("Sonora".utf8)
        var comments: [Data] = []
        if let existing = blocks.first(where: { $0.type == BlockType.vorbisComment }) {
            let parsed = try parseVorbisComment(existing.body)
            vendor = parsed.vendor
            comments = parsed.comments
        }

        applyFields(tags, artwork: artwork, to: &comments)

        // 3. Pictures.
        var newPicture: Block?
        if case .replace(let image) = artwork {
            newPicture = Block(type: BlockType.picture, body: try pictureBody(image))
        }
        let dropCovers: Bool
        switch artwork {
        case .keep: dropCovers = false
        case .remove, .replace: dropCovers = true
        }

        // 4. Assemble: STREAMINFO, VORBIS_COMMENT, new PICTURE, kept blocks, PADDING.
        var output: [Block] = [first]
        output.append(Block(type: BlockType.vorbisComment,
                            body: try buildVorbisComment(vendor: vendor, comments: comments)))
        if let picture = newPicture {
            output.append(picture)
        }
        for block in blocks.dropFirst() {
            switch block.type {
            case BlockType.streamInfo, BlockType.vorbisComment, BlockType.padding:
                continue
            case BlockType.picture:
                if dropCovers && isCoverPicture(block.body) { continue }
                output.append(block)
            default:
                output.append(block)
            }
        }
        output.append(Block(type: BlockType.padding, body: Data(count: paddingSize)))

        // 5. Serialise.
        var data = Data()
        data.reserveCapacity(file.count - audioStart + 8192 + output.reduce(0) { $0 + $1.body.count })
        data.append(contentsOf: [0x66, 0x4C, 0x61, 0x43]) // "fLaC"
        for (index, block) in output.enumerated() {
            guard block.body.count <= maxBlockLength else {
                throw TagWriteError.writeFailed(block.type == BlockType.picture
                                                ? "artwork too large" : "tags too large")
            }
            let isLast = index == output.count - 1
            let headerByte: UInt8 = (isLast ? 0x80 : 0x00) | (block.type & 0x7F)
            data.append(headerByte)
            let length = UInt32(block.body.count)
            data.append(UInt8((length >> 16) & 0xFF))
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
            data.append(block.body)
        }
        if audioStart < file.count {
            data.append(file.subdata(in: (file.startIndex + audioStart)..<file.endIndex))
        }

        try TagWriter.replaceFile(at: url, with: data)
    }

    // MARK: - Vorbis comments

    /// Replaces every entry for each edited field. An empty string only removes.
    private static func applyFields(_ tags: TagSet, artwork: ArtworkChange, to comments: inout [Data]) {
        // Track total hidden in an old "n/total" TRACKNUMBER survives a number-only edit.
        var carriedTotal: String?
        if tags.trackNumber != nil, tags.trackTotal == nil,
           !hasKey(comments, ["TRACKTOTAL", "TOTALTRACKS"]),
           let old = firstValue(comments, "TRACKNUMBER") {
            let parts = old.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                let total = parts[1].trimmingCharacters(in: .whitespaces)
                if let n = Int(total), n > 0 { carriedTotal = String(n) }
            }
        }

        func setField(_ keys: [String], _ value: String?) {
            guard let value = value else { return }
            comments.removeAll { keyMatches($0, keys) }
            if !value.isEmpty {
                comments.append(Data("\(keys[0])=\(value)".utf8))
            }
        }
        func numberText(_ value: Int?) -> String? {
            guard let value = value else { return nil }
            return value > 0 ? String(value) : ""
        }

        setField(["TITLE"], tags.title)
        setField(["ARTIST"], tags.artist)
        setField(["ALBUMARTIST", "ALBUM ARTIST"], tags.albumArtist)
        setField(["ALBUM"], tags.album)
        setField(["GENRE"], tags.genre)
        setField(["COMPOSER"], tags.composer)
        setField(["DATE"], numberText(tags.year))
        setField(["TRACKNUMBER"], numberText(tags.trackNumber))
        setField(["TRACKTOTAL", "TOTALTRACKS"], numberText(tags.trackTotal))
        if let total = carriedTotal {
            comments.append(Data("TRACKTOTAL=\(total)".utf8))
        }
        setField(["DISCNUMBER"], numberText(tags.discNumber))
        setField(["COMMENT", "DESCRIPTION"], tags.comment)
        setField(["LYRICS", "UNSYNCEDLYRICS"], tags.lyrics)

        switch artwork {
        case .keep:
            break
        case .remove, .replace:
            // Ogg-style embedded pictures would otherwise resurface.
            comments.removeAll { keyMatches($0, ["METADATA_BLOCK_PICTURE", "COVERART", "COVERARTMIME"]) }
        }
    }

    private static func parseVorbisComment(_ body: Data) throws -> (vendor: Data, comments: [Data]) {
        var pos = 0
        func readLength() throws -> Int {
            guard pos + 4 <= body.count else {
                throw TagWriteError.malformed("truncated Vorbis comment")
            }
            let value = Int(byte(body, pos)) | Int(byte(body, pos + 1)) << 8
                | Int(byte(body, pos + 2)) << 16 | Int(byte(body, pos + 3)) << 24
            pos += 4
            return value
        }
        func readBytes(_ count: Int) throws -> Data {
            guard count <= body.count - pos else {
                throw TagWriteError.malformed("Vorbis comment entry overruns its block")
            }
            let slice = body.subdata(in: (body.startIndex + pos)..<(body.startIndex + pos + count))
            pos += count
            return slice
        }

        let vendor = try readBytes(try readLength())
        let count = try readLength()
        // Each entry needs at least its 4-byte length.
        guard count <= (body.count - pos) / 4 else {
            throw TagWriteError.malformed("bad Vorbis comment count")
        }
        var comments: [Data] = []
        comments.reserveCapacity(count)
        for _ in 0..<count {
            let entry = try readBytes(try readLength())
            if !entry.isEmpty { comments.append(entry) }
        }
        return (vendor, comments)
    }

    private static func buildVorbisComment(vendor: Data, comments: [Data]) throws -> Data {
        var data = Data()
        appendUInt32LE(UInt32(vendor.count), to: &data)
        data.append(vendor)
        appendUInt32LE(UInt32(comments.count), to: &data)
        for entry in comments {
            guard entry.count <= maxBlockLength else {
                throw TagWriteError.writeFailed("tags too large")
            }
            appendUInt32LE(UInt32(entry.count), to: &data)
            data.append(entry)
        }
        return data
    }

    /// Case-insensitive match on the part before "=" (ASCII keys only).
    private static func keyMatches(_ entry: Data, _ keys: [String]) -> Bool {
        guard let key = entryKey(entry) else { return false }
        return keys.contains { $0.uppercased() == key }
    }

    private static func entryKey(_ entry: Data) -> String? {
        guard let eq = entry.firstIndex(of: 0x3D) else { return nil } // "="
        let keyBytes = entry[entry.startIndex..<eq]
        return String(decoding: keyBytes, as: UTF8.self).uppercased()
    }

    private static func hasKey(_ comments: [Data], _ keys: [String]) -> Bool {
        comments.contains { keyMatches($0, keys) }
    }

    private static func firstValue(_ comments: [Data], _ key: String) -> String? {
        guard let entry = comments.first(where: { keyMatches($0, [key]) }),
              let eq = entry.firstIndex(of: 0x3D) else { return nil }
        let valueBytes = entry[entry.index(after: eq)..<entry.endIndex]
        return String(decoding: valueBytes, as: UTF8.self)
    }

    // MARK: - Pictures

    /// Front cover (type 3) or "Other" (type 0, which many taggers use for the cover).
    private static func isCoverPicture(_ body: Data) -> Bool {
        guard body.count >= 4 else { return false }
        let type = UInt32(byte(body, 0)) << 24 | UInt32(byte(body, 1)) << 16
            | UInt32(byte(body, 2)) << 8 | UInt32(byte(body, 3))
        return type == 3 || type == 0
    }

    /// PICTURE block body (all fields big-endian).
    private static func pictureBody(_ image: Data) throws -> Data {
        let mime: String
        var depth: UInt32 = 24
        if image.count >= 3, byte(image, 0) == 0xFF, byte(image, 1) == 0xD8, byte(image, 2) == 0xFF {
            mime = "image/jpeg"
        } else if image.count >= 8,
                  [UInt8](image.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            mime = "image/png"
        } else {
            throw TagWriteError.writeFailed("the artwork must be a JPEG or PNG image")
        }
        // 32 bytes of fixed fields + MIME + data must fit the 24-bit block length.
        guard image.count <= maxBlockLength - 32 - mime.utf8.count else {
            throw TagWriteError.writeFailed("artwork too large")
        }

        var width: UInt32 = 0
        var height: UInt32 = 0
        if let source = CGImageSourceCreateWithData(image as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.uint32Value ?? 0
            height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.uint32Value ?? 0
            if mime == "image/png", (properties[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue == true {
                depth = 32
            }
        }

        var body = Data()
        appendUInt32BE(3, to: &body)                          // front cover
        appendUInt32BE(UInt32(mime.utf8.count), to: &body)
        body.append(contentsOf: Array(mime.utf8))
        appendUInt32BE(0, to: &body)                          // description length
        appendUInt32BE(width, to: &body)
        appendUInt32BE(height, to: &body)
        appendUInt32BE(depth, to: &body)
        appendUInt32BE(0, to: &body)                          // colours (non-indexed)
        appendUInt32BE(UInt32(image.count), to: &body)
        body.append(image)
        return body
    }

    // MARK: - Leading ID3v2

    /// Size of an ID3v2 tag at the start of the file (0 if none).
    private static func leadingID3Size(_ file: Data) throws -> Int {
        guard file.count >= 10,
              byte(file, 0) == 0x49, byte(file, 1) == 0x44, byte(file, 2) == 0x33 else { return 0 } // "ID3"
        var size = 0
        for i in 6..<10 {
            let b = byte(file, i)
            guard b < 0x80 else {
                throw TagWriteError.malformed("invalid ID3 tag in front of FLAC data")
            }
            size = (size << 7) | Int(b)
        }
        var total = 10 + size
        if (byte(file, 5) & 0x10) != 0 { total += 10 } // footer
        guard total <= file.count else {
            throw TagWriteError.malformed("ID3 tag is larger than the file")
        }
        return total
    }

    // MARK: - Byte helpers (offsets relative to `data.startIndex`; callers bounds-check)

    private static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
