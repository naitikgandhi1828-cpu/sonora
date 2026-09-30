//
//  ID3TagWriter.swift
//  Sonora
//
//  Rewrites the ID3v2 tag at the start of an MP3 file as an ID3v2.3 tag.
//
//  • An existing v2.3 / v2.4 tag is parsed and every frame Sonora doesn't
//    touch is carried over (v2.4 frames are converted to v2.3 layout; frames
//    that can't be represented in v2.3 are dropped).
//  • A v2.2 tag, or a tag with whole-tag unsynchronisation, is dropped and a
//    fresh tag containing only Sonora's fields is written.
//  • The audio after the tag is copied verbatim. A trailing ID3v1 block is
//    removed when a field it also stores changes (so stale values can't win).
//

import Foundation

enum ID3TagWriter {

    /// Zero padding appended after the frames so later edits can grow in place.
    private static let paddingSize = 1024

    /// One ID3v2.3 frame, ready to be re-emitted.
    private struct Frame {
        var id: String
        /// Frame content (copied, so it is 0-indexed).
        var body: Data
        var flag1: UInt8
        var flag2: UInt8
    }

    // MARK: - Entry point

    static func write(_ tags: TagSet, artwork: ArtworkChange, to url: URL) throws {
        let file: Data
        do {
            file = try Data(contentsOf: url)
        } catch {
            throw TagWriteError.unreadable(error.localizedDescription)
        }

        // 1. Existing tag (if any).
        let existing = try parseExistingTag(file)
        var frames = existing.frames
        let audioStart = existing.tagEnd

        // 2. Read what we need from the old frames before dropping them.
        let oldTrack = splitNumberPair(textValue(of: "TRCK", in: frames))
        let oldDisc = splitNumberPair(textValue(of: "TPOS", in: frames))

        // 3. Replace the edited fields.
        setText("TIT2", tags.title, in: &frames)
        setText("TPE1", tags.artist, in: &frames)
        setText("TPE2", tags.albumArtist, in: &frames)
        setText("TALB", tags.album, in: &frames)
        setText("TCON", tags.genre, in: &frames)
        setText("TCOM", tags.composer, in: &frames)

        if let year = tags.year {
            frames.removeAll { $0.id == "TYER" || $0.id == "TDRC" }
            if year > 0 {
                frames.append(textFrame("TYER", String(year)))
            }
        }

        if tags.trackNumber != nil || tags.trackTotal != nil {
            let number = tags.trackNumber ?? oldTrack.number
            let total = tags.trackTotal ?? oldTrack.total
            frames.removeAll { $0.id == "TRCK" }
            if let pair = formatNumberPair(number, total) {
                frames.append(textFrame("TRCK", pair))
            }
        }

        if let disc = tags.discNumber {
            frames.removeAll { $0.id == "TPOS" }
            if let pair = formatNumberPair(disc, oldDisc.total) {
                frames.append(textFrame("TPOS", pair))
            }
        }

        if let comment = tags.comment {
            // Keep iTunes' private COMM frames (iTunNORM, iTunSMPB gapless info…).
            frames.removeAll { $0.id == "COMM" && !commentDescription($0.body).hasPrefix("iTun") }
            if !comment.isEmpty {
                frames.append(languageTextFrame("COMM", comment))
            }
        }

        if let lyrics = tags.lyrics {
            frames.removeAll { $0.id == "USLT" }
            if !lyrics.isEmpty {
                frames.append(languageTextFrame("USLT", lyrics))
            }
        }

        switch artwork {
        case .keep:
            break
        case .remove:
            frames.removeAll { $0.id == "APIC" }
        case .replace(let image):
            frames.removeAll { $0.id == "APIC" }
            frames.append(try pictureFrame(image))
        }

        // 4. Serialise the new tag.
        var body = Data()
        for frame in frames {
            guard frame.body.count <= Int(UInt32.max) else {
                throw TagWriteError.writeFailed("a tag frame is too large")
            }
            body.append(contentsOf: Array(frame.id.utf8))
            appendUInt32BE(UInt32(frame.body.count), to: &body)
            body.append(frame.flag1)
            body.append(frame.flag2)
            body.append(frame.body)
        }
        body.append(Data(count: paddingSize))

        guard body.count <= 0x0FFF_FFFF else {
            throw TagWriteError.writeFailed("the tag is too large (artwork over 256 MB?)")
        }

        var output = Data()
        output.reserveCapacity(10 + body.count + max(0, file.count - audioStart))
        output.append(contentsOf: [0x49, 0x44, 0x33, 0x03, 0x00, 0x00]) // "ID3" v2.3.0, no flags
        output.append(contentsOf: encodeSyncsafe(UInt32(body.count)))
        output.append(body)

        // 5. Audio (and an ID3v1 block unless a field it holds changed).
        var audioEnd = file.count
        if hasID3v1(file, audioStart: audioStart) {
            let textChanged: Bool = tags.title != nil || tags.artist != nil || tags.album != nil
            let otherChanged: Bool = tags.year != nil || tags.comment != nil
                || tags.genre != nil || tags.trackNumber != nil
            if textChanged || otherChanged {
                audioEnd = file.count - 128
            }
        }
        if audioEnd > audioStart {
            output.append(file.subdata(in: (file.startIndex + audioStart)..<(file.startIndex + audioEnd)))
        }

        try TagWriter.replaceFile(at: url, with: output)
    }

    // MARK: - Parsing the existing tag

    private struct ExistingTag {
        var frames: [Frame]
        /// Offset of the first byte after the tag (and its footer); 0 if no tag.
        var tagEnd: Int
    }

    private static func parseExistingTag(_ file: Data) throws -> ExistingTag {
        guard file.count >= 10,
              byte(file, 0) == 0x49, byte(file, 1) == 0x44, byte(file, 2) == 0x33 else {
            return ExistingTag(frames: [], tagEnd: 0)
        }
        let major = byte(file, 3)
        let flags = byte(file, 5)
        guard major >= 2 && major <= 4 else {
            throw TagWriteError.malformed("unsupported ID3v2 version 2.\(major)")
        }
        let size = Int(try decodeSyncsafe(file, at: 6))
        var tagEnd = 10 + size
        if major == 4 && (flags & 0x10) != 0 {
            tagEnd += 10 // footer
        }
        guard tagEnd <= file.count else {
            throw TagWriteError.malformed("ID3 tag is larger than the file")
        }

        // v2.2 (3-character frame ids) and unsynchronised tags: start fresh.
        if major == 2 || (flags & 0x80) != 0 {
            return ExistingTag(frames: [], tagEnd: tagEnd)
        }

        let framesEnd = 10 + size
        var pos = 10

        // Extended header: skip it.
        if (flags & 0x40) != 0 {
            guard pos + 4 <= framesEnd else {
                throw TagWriteError.malformed("truncated extended header")
            }
            if major == 3 {
                // Size excludes its own 4 bytes.
                pos += 4 + Int(readUInt32BE(file, at: pos))
            } else {
                // Syncsafe size includes itself.
                let extSize = Int(try decodeSyncsafe(file, at: pos))
                guard extSize >= 6 else {
                    throw TagWriteError.malformed("bad extended header size")
                }
                pos += extSize
            }
            guard pos <= framesEnd else {
                throw TagWriteError.malformed("extended header overruns the tag")
            }
        }

        var frames: [Frame] = []
        while pos + 10 <= framesEnd {
            // Padding starts with a zero byte.
            if byte(file, pos) == 0 { break }

            let idBytes = [byte(file, pos), byte(file, pos + 1), byte(file, pos + 2), byte(file, pos + 3)]
            guard idBytes.allSatisfy(isFrameIDByte) else {
                // Garbage where frames should be: treat it as the end of the frames.
                break
            }
            let id = String(decoding: idBytes, as: UTF8.self)

            let frameSize: Int
            if major == 4 {
                // Some writers (old iTunes) put plain big-endian sizes in v2.4.
                if let syncsafe = try? decodeSyncsafe(file, at: pos + 4) {
                    frameSize = Int(syncsafe)
                } else {
                    frameSize = Int(readUInt32BE(file, at: pos + 4))
                }
            } else {
                frameSize = Int(readUInt32BE(file, at: pos + 4))
            }
            let flag1 = byte(file, pos + 8)
            let flag2 = byte(file, pos + 9)
            let bodyStart = pos + 10
            guard frameSize <= framesEnd - bodyStart else {
                throw TagWriteError.malformed("frame \(id) overruns the tag")
            }
            let body = file.subdata(in: (file.startIndex + bodyStart)..<(file.startIndex + bodyStart + frameSize))
            pos = bodyStart + frameSize

            if frameSize == 0 { continue }

            if major == 3 {
                frames.append(Frame(id: id, body: body, flag1: flag1, flag2: flag2))
            } else if let converted = convertV24Frame(id: id, body: body, formatFlags: flag2) {
                frames.append(converted)
            }
        }

        if major == 4 {
            convertRecordingTime(in: &frames)
        }
        return ExistingTag(frames: frames, tagEnd: tagEnd)
    }

    /// Converts a v2.4 frame to v2.3 layout, or returns nil when it can't be
    /// carried over safely.
    private static func convertV24Frame(id: String, body: Data, formatFlags: UInt8) -> Frame? {
        // Compression, encryption, grouping, frame unsynchronisation or a data
        // length indicator all change the body layout: drop those frames.
        guard formatFlags == 0 else { return nil }

        if hasEncodingByte(id), let encoding = body.first, encoding == 0x03 {
            // UTF-8 exists only in v2.4. Re-encode simple text frames, drop the rest.
            guard id.hasPrefix("T"), id != "TXXX" else { return nil }
            let text = decodeText(body.subdata(in: (body.startIndex + 1)..<body.endIndex), encoding: 0x03)
            // v2.4 separates multiple values with NULs; v2.3 readers expect "/".
            let joined = text.split(separator: "\u{0}", omittingEmptySubsequences: true).joined(separator: "/")
            if joined.isEmpty { return nil }
            return textFrame(id, joined)
        }
        // Status flags (tag/file alter preservation, read only) mean
        // different bits in v2.4; clear them.
        return Frame(id: id, body: body, flag1: 0, flag2: 0)
    }

    /// v2.3 has no TDRC; turn it into TYER when there isn't one already.
    private static func convertRecordingTime(in frames: inout [Frame]) {
        guard let index = frames.firstIndex(where: { $0.id == "TDRC" }) else { return }
        let hasYear = frames.contains { $0.id == "TYER" }
        let value = textValue(of: "TDRC", in: frames) ?? ""
        let digits = String(value.prefix(4))
        frames.remove(at: index)
        if !hasYear, digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
            frames.append(textFrame("TYER", digits))
        }
    }

    // MARK: - Building frames

    private static func setText(_ id: String, _ value: String?, in frames: inout [Frame]) {
        guard let value = value else { return }
        frames.removeAll { $0.id == id }
        if !value.isEmpty {
            frames.append(textFrame(id, value))
        }
    }

    /// Text frame: encoding 0x01 (UTF-16 with BOM) + text, no terminator.
    private static func textFrame(_ id: String, _ text: String) -> Frame {
        var body = Data([0x01])
        body.append(utf16WithBOM(text))
        return Frame(id: id, body: body, flag1: 0, flag2: 0)
    }

    /// COMM / USLT: encoding, language "eng", empty description (BOM + 00 00), text.
    private static func languageTextFrame(_ id: String, _ text: String) -> Frame {
        var body = Data([0x01, 0x65, 0x6E, 0x67]) // UTF-16, "eng"
        body.append(utf16WithBOM(""))
        body.append(contentsOf: [0x00, 0x00])
        body.append(utf16WithBOM(text))
        return Frame(id: id, body: body, flag1: 0, flag2: 0)
    }

    /// APIC: encoding 0x00, MIME + 00, picture type 3 (front cover), empty description + 00, data.
    private static func pictureFrame(_ image: Data) throws -> Frame {
        guard let mime = imageMIMEType(image) else {
            throw TagWriteError.writeFailed("the artwork must be a JPEG or PNG image")
        }
        var body = Data([0x00])
        body.append(contentsOf: Array(mime.utf8))
        body.append(contentsOf: [0x00, 0x03, 0x00])
        body.append(image)
        return Frame(id: "APIC", body: body, flag1: 0, flag2: 0)
    }

    private static func utf16WithBOM(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 {
            data.append(UInt8(unit & 0x00FF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    private static func imageMIMEType(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(8))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF {
            return "image/jpeg"
        }
        if head.count >= 8, head == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        return nil
    }

    // MARK: - Reading frame values

    /// Frames whose first body byte is a text encoding.
    private static func hasEncodingByte(_ id: String) -> Bool {
        if id.hasPrefix("T") { return true }
        switch id {
        case "COMM", "USLT", "APIC", "WXXX", "SYLT", "USER", "GEOB", "IPLS", "OWNE", "COMR":
            return true
        default:
            return false
        }
    }

    /// First value of a text frame, or nil when absent/undecodable.
    private static func textValue(of id: String, in frames: [Frame]) -> String? {
        guard let frame = frames.first(where: { $0.id == id }),
              let encoding = frame.body.first else { return nil }
        let text = decodeText(frame.body.subdata(in: (frame.body.startIndex + 1)..<frame.body.endIndex),
                              encoding: encoding)
        guard let first = text.split(separator: "\u{0}", omittingEmptySubsequences: true).first else {
            return nil
        }
        return String(first)
    }

    /// Description string of a COMM frame ("" when empty or undecodable).
    private static func commentDescription(_ body: Data) -> String {
        let bytes = [UInt8](body)
        guard bytes.count >= 4 else { return "" }
        let encoding = bytes[0]
        var start = 4
        var end = bytes.count
        if encoding == 0x01 || encoding == 0x02 {
            // Two-byte, aligned terminator.
            var i = start
            while i + 1 < bytes.count {
                if bytes[i] == 0 && bytes[i + 1] == 0 { end = i; break }
                i += 2
            }
        } else {
            if let nul = bytes[start...].firstIndex(of: 0) { end = nul }
        }
        if end < start { start = end }
        return decodeText(Data(bytes[start..<end]), encoding: encoding)
    }

    /// Decodes ID3 text in the given encoding (0 Latin-1, 1 UTF-16 BOM, 2 UTF-16BE, 3 UTF-8).
    private static func decodeText(_ raw: Data, encoding: UInt8) -> String {
        var bytes = [UInt8](raw)
        let text: String?
        switch encoding {
        case 0x00:
            text = String(bytes: bytes, encoding: .isoLatin1)
        case 0x01, 0x02:
            var bigEndian = encoding == 0x02
            if bytes.count >= 2 {
                if bytes[0] == 0xFF && bytes[1] == 0xFE {
                    bigEndian = false
                    bytes.removeFirst(2)
                } else if bytes[0] == 0xFE && bytes[1] == 0xFF {
                    bigEndian = true
                    bytes.removeFirst(2)
                }
            }
            if bytes.count % 2 == 1 { bytes.removeLast() }
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var i = 0
            while i + 1 < bytes.count {
                let a = UInt16(bytes[i])
                let b = UInt16(bytes[i + 1])
                units.append(bigEndian ? (a << 8 | b) : (b << 8 | a))
                i += 2
            }
            text = String(decoding: units, as: UTF16.self)
        case 0x03:
            text = String(decoding: bytes, as: UTF8.self)
        default:
            text = nil
        }
        guard var result = text else { return "" }
        while result.hasSuffix("\u{0}") { result.removeLast() }
        return result
    }

    /// Splits "n" or "n/total".
    private static func splitNumberPair(_ text: String?) -> (number: Int?, total: Int?) {
        guard let text = text else { return (nil, nil) }
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let number = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let total = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (number, total)
    }

    /// "n" or "n/total"; nil when there's no usable number (0 clears the field).
    private static func formatNumberPair(_ number: Int?, _ total: Int?) -> String? {
        guard let number = number, number > 0 else { return nil }
        if let total = total, total > 0 {
            return "\(number)/\(total)"
        }
        return String(number)
    }

    // MARK: - ID3v1

    private static func hasID3v1(_ file: Data, audioStart: Int) -> Bool {
        guard file.count - audioStart >= 128 else { return false }
        let at = file.count - 128
        return byte(file, at) == 0x54 && byte(file, at + 1) == 0x41 && byte(file, at + 2) == 0x47 // "TAG"
    }

    // MARK: - Byte helpers (offsets are relative to `data.startIndex`; callers bounds-check)

    private static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    private static func isFrameIDByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) // A-Z, 0-9
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(byte(data, offset)) << 24 | UInt32(byte(data, offset + 1)) << 16
            | UInt32(byte(data, offset + 2)) << 8 | UInt32(byte(data, offset + 3))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    /// Reads a 4-byte syncsafe integer; throws if any byte has its high bit set.
    private static func decodeSyncsafe(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw TagWriteError.malformed("truncated size field")
        }
        var value: UInt32 = 0
        for i in 0..<4 {
            let b = byte(data, offset + i)
            guard b < 0x80 else {
                throw TagWriteError.malformed("invalid syncsafe size")
            }
            value = (value << 7) | UInt32(b)
        }
        return value
    }

    /// Encodes a value below 2^28 as 4 syncsafe bytes.
    private static func encodeSyncsafe(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
         UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }
}
