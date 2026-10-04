//
//  AudioFileDoctor.swift
//  Sonora
//
//  Opens an audio file for playback, and when iOS refuses the file as it is,
//  works out why and repairs what can be repaired.
//
//  iOS reads audio through one strict parser. A file can be perfectly good
//  music and still be refused, most often for one of these reasons:
//
//    1. The name lies. A file called "song.mp3" is really an M4A, AAC, FLAC or
//       WAV file (many download sites do this). iOS trusts the extension and
//       gives up. Fix: open it through a correctly-named alias.
//    2. There is junk in front of the music. Two tags stacked on top of each
//       other, a tag whose stated size is wrong, or an MP3 wrapped inside a
//       WAV container. Fix: find where the real MP3 frames start and play a
//       trimmed copy.
//    3. The file is not on the phone. It lives in iCloud and has been
//       offloaded, or it was moved or deleted since the last scan.
//    4. It is a format iPhones cannot decode at all (WebM/Opus, Ogg, WMA)
//       that merely carries an .mp3 name.
//
//  Repaired copies live in the Caches folder, which iOS may empty at any
//  time; they are rebuilt on demand and never touch the original file.
//

import Foundation
import AVFoundation
import CryptoKit

enum AudioFileDoctor {

    enum Problem {
        /// Stored in iCloud and not downloaded; a download has been requested.
        case downloading
        /// Not where the library says it is.
        case missing
        /// A format iOS cannot decode.
        case unsupported
        /// Damaged, empty, or unreadable for a reason we could not pin down.
        case unreadable
    }

    struct Failure: Error {
        let problem: Problem
        /// Plain-language explanation for the alert.
        let message: String
    }

    // MARK: - Entry point

    static func open(_ url: URL) -> Result<AVAudioFile, Failure> {
        let name = url.lastPathComponent

        // The normal case: iOS opens it straight away.
        var systemError: NSError?
        do {
            let file = try AVAudioFile(forReading: url)
            if isUsable(file) { return .success(file) }
        } catch {
            systemError = error as NSError
        }

        if let failure = availabilityProblem(url, name: name) {
            return .failure(failure)
        }

        // Memory-mapped, so even a large file costs no real memory here.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16 else {
            return .failure(Failure(problem: .unreadable,
                                    message: "“\(name)” is empty or could not be read."))
        }

        // Look at the very start, and also just past any ID3 tag: a tag can be
        // glued onto the front of a file that is not an MP3 at all.
        let tagEnd = id3TagEnd(data)
        let atStart = sniff(data, at: 0)
        let afterTag = tagEnd > 0 ? sniff(data, at: tagEnd) : nil
        let kind: Kind
        let skip: Int
        if let afterTag, afterTag != .mp3 {
            kind = afterTag
            skip = tagEnd
        } else {
            kind = atStart ?? .unknown
            skip = 0
        }
        let currentExt = url.pathExtension.lowercased()

        switch kind {
        case .oggOrOpus, .webm, .wma, .monkeysAudio:
            return .failure(Failure(problem: .unsupported,
                message: "“\(name)” is not really \(article(currentExt)) file. It is \(kind.displayName) with \(article(currentExt)) name, and iPhones cannot play that format. Convert it to MP3 or M4A on your laptop."))

        case .mp4, .flac, .aiff, .caf, .adts, .wav:
            // A real container under the wrong name (or behind a stray tag).
            if let ext = kind.fileExtension, ext != currentExt || skip > 0 {
                if let file = openRenamed(url, data: data, skipping: skip, ext: ext) {
                    return .success(file)
                }
            }
            // WAV files sometimes just wrap MP3 data: fall through to the MP3 scan.
            if kind != .wav { break }
            fallthrough

        case .mp3, .unknown:
            // Trust the tag's stated size only when audio really does start
            // right after it. A tag that claims to be longer than it is would
            // otherwise make us skip the opening seconds of the song.
            var offset = firstMPEGFrame(in: data, startingAt: tagEnd)
            if offset != tagEnd {
                offset = firstMPEGFrame(in: data, startingAt: 0) ?? offset
            }
            if let offset, let file = openTrimmedMP3(url, data: data, from: offset) {
                return .success(file)
            }
        }

        let code = systemError.map { " (iOS error \($0.code))" } ?? ""
        return .failure(Failure(problem: .unreadable,
            message: "“\(name)” could not be played\(code). The file looks damaged or is in a format iPhones cannot decode."))
    }

    /// True once an iCloud file has finished downloading (or was never in iCloud).
    static func isOnDevice(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus {
            return status != .notDownloaded
        }
        return true
    }

    // MARK: - Is the file even there?

    private static func availabilityProblem(_ url: URL, name: String) -> Failure? {
        let fm = FileManager.default
        let cloudMessage = "“\(name)” is stored in iCloud and is not on this iPhone yet. Sonora has asked iCloud to download it and will play it as soon as it arrives."

        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return Failure(problem: .downloading, message: cloudMessage)
        }

        if !fm.fileExists(atPath: url.path) {
            // An offloaded iCloud file leaves a hidden ".name.icloud" stub behind.
            let stub = url.deletingLastPathComponent().appendingPathComponent("." + name + ".icloud")
            if fm.fileExists(atPath: stub.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return Failure(problem: .downloading, message: cloudMessage)
            }
            return Failure(problem: .missing,
                message: "“\(name)” is no longer in its folder. It may have been moved, renamed or deleted. Rescan your folders in Settings → Library.")
        }
        return nil
    }

    // MARK: - What is it really?

    private enum Kind {
        case mp3, mp4, flac, wav, aiff, caf, adts
        case oggOrOpus, webm, wma, monkeysAudio
        case unknown

        /// The extension iOS expects for this kind of file.
        var fileExtension: String? {
            switch self {
            case .mp3: return "mp3"
            case .mp4: return "m4a"
            case .flac: return "flac"
            case .wav: return "wav"
            case .aiff: return "aiff"
            case .caf: return "caf"
            case .adts: return "aac"
            default: return nil
            }
        }

        var displayName: String {
            switch self {
            case .oggOrOpus: return "an Ogg (Vorbis or Opus) file"
            case .webm: return "a WebM file"
            case .wma: return "a Windows Media (WMA) file"
            case .monkeysAudio: return "a Monkey's Audio (APE) file"
            default: return "a different kind of file"
            }
        }
    }

    private static func article(_ ext: String) -> String {
        let upper = ext.isEmpty ? "audio" : ext.uppercased()
        // "an MP3", "an M4A", "an AAC", "an OGG" - but "a WAV", "a FLAC".
        let vowelSound = upper.first.map { "AEFHILMNORSX".contains($0) } ?? false
        return (vowelSound ? "an " : "a ") + upper
    }

    /// Identifies a file by the first bytes at `offset`; nil when nothing matches.
    private static func sniff(_ data: Data, at offset: Int) -> Kind? {
        guard offset >= 0, offset + 12 <= data.count else { return nil }
        func b(_ i: Int) -> UInt8 { data[data.startIndex + offset + i] }
        func tag(_ i: Int, _ text: String) -> Bool {
            let bytes = Array(text.utf8)
            for (k, value) in bytes.enumerated() where b(i + k) != value { return false }
            return true
        }

        if tag(4, "ftyp") { return .mp4 }
        if tag(0, "fLaC") { return .flac }
        if tag(0, "RIFF") && tag(8, "WAVE") { return .wav }
        if tag(0, "FORM") && (tag(8, "AIFF") || tag(8, "AIFC")) { return .aiff }
        if tag(0, "caff") { return .caf }
        if tag(0, "OggS") { return .oggOrOpus }
        if b(0) == 0x1A && b(1) == 0x45 && b(2) == 0xDF && b(3) == 0xA3 { return .webm }
        if b(0) == 0x30 && b(1) == 0x26 && b(2) == 0xB2 && b(3) == 0x75 { return .wma }
        if tag(0, "MAC ") { return .monkeysAudio }
        if tag(0, "ID3") { return .mp3 }
        if b(0) == 0xFF && (b(1) & 0xF6) == 0xF0 { return .adts }   // sync + layer bits 00
        if b(0) == 0xFF && (b(1) & 0xE0) == 0xE0 { return .mp3 }
        return nil
    }

    /// Offset just past every ID3v2 tag stacked at the start of the file.
    private static func id3TagEnd(_ data: Data) -> Int {
        var pos = 0
        let n = data.count
        func b(_ i: Int) -> UInt8 { data[data.startIndex + i] }
        while pos + 10 <= n, b(pos) == 0x49, b(pos + 1) == 0x44, b(pos + 2) == 0x33 {
            let s = [b(pos + 6), b(pos + 7), b(pos + 8), b(pos + 9)]
            guard s.allSatisfy({ $0 < 0x80 }) else { break }
            let size = Int(s[0]) << 21 | Int(s[1]) << 14 | Int(s[2]) << 7 | Int(s[3])
            var end = pos + 10 + size
            if (b(pos + 5) & 0x10) != 0 { end += 10 }   // v2.4 footer
            guard end <= n else { break }
            pos = end
        }
        return pos
    }

    // MARK: - Finding the real MP3 audio

    private struct FrameHeader {
        let version: UInt8      // 0 = MPEG 2.5, 2 = MPEG 2, 3 = MPEG 1
        let layer: UInt8        // 1 = Layer III, 2 = Layer II, 3 = Layer I
        let sampleRateIndex: UInt8
        let length: Int
    }

    /// Bit rates in kbit/s, indexed [table][bitrate index 1...14].
    private static let bitrates: [[Int]] = [
        [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],   // MPEG 1, Layer I
        [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],      // MPEG 1, Layer II
        [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],       // MPEG 1, Layer III
        [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],      // MPEG 2/2.5, Layer I
        [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]            // MPEG 2/2.5, Layer II & III
    ]

    private static func parseFrame(_ p: UnsafeBufferPointer<UInt8>, at i: Int) -> FrameHeader? {
        guard i >= 0, i + 4 <= p.count, p[i] == 0xFF, (p[i + 1] & 0xE0) == 0xE0 else { return nil }
        let version = (p[i + 1] >> 3) & 0x03
        let layer = (p[i + 1] >> 1) & 0x03
        let bitrateIndex = Int(p[i + 2] >> 4)
        let sampleRateIndex = (p[i + 2] >> 2) & 0x03
        let padding = Int((p[i + 2] >> 1) & 0x01)
        guard version != 1, layer != 0, bitrateIndex != 0, bitrateIndex != 15, sampleRateIndex != 3 else {
            return nil
        }

        let table: Int
        if version == 3 {
            table = layer == 3 ? 0 : (layer == 2 ? 1 : 2)
        } else {
            table = layer == 3 ? 3 : 4
        }
        let bitrate = bitrates[table][bitrateIndex - 1] * 1000

        let baseRates = [44_100, 48_000, 32_000]
        var sampleRate = baseRates[Int(sampleRateIndex)]
        if version == 2 { sampleRate /= 2 }
        if version == 0 { sampleRate /= 4 }

        let length: Int
        if layer == 3 {                                   // Layer I
            length = (12 * bitrate / sampleRate + padding) * 4
        } else if layer == 1 && version != 3 {            // Layer III, MPEG 2 / 2.5
            length = 72 * bitrate / sampleRate + padding
        } else {                                          // Layer II, or Layer III MPEG 1
            length = 144 * bitrate / sampleRate + padding
        }
        guard length >= 24 else { return nil }
        return FrameHeader(version: version, layer: layer, sampleRateIndex: sampleRateIndex, length: length)
    }

    /// Offset of the first place where four MPEG audio frames follow one
    /// another exactly. One matching header can be a coincidence inside a
    /// picture or tag; four in a row, each exactly where the last one says the
    /// next should be, is audio.
    private static func firstMPEGFrame(in data: Data, startingAt start: Int) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            guard start >= 0, start < n else { return nil }
            // Looking further than this is not worth the time: no real tag or
            // wrapper is bigger.
            let limit = min(n - 4, start + 16 * 1024 * 1024)
            var i = start
            while i < limit {
                if p[i] == 0xFF, let first = parseFrame(p, at: i) {
                    var next = i + first.length
                    var matched = 1
                    while matched < 4, let frame = parseFrame(p, at: next),
                          frame.version == first.version, frame.layer == first.layer,
                          frame.sampleRateIndex == first.sampleRateIndex {
                        next += frame.length
                        matched += 1
                    }
                    if matched >= 4 { return i }
                }
                i += 1
            }
            return nil
        }
    }

    // MARK: - Repaired copies

    private static let cacheLimitBytes: Int64 = 400 * 1024 * 1024

    private static var cacheFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SonoraPlayable", isDirectory: true)
    }

    /// A cache name that changes whenever the original file does.
    private static func cacheURL(for url: URL, label: String, ext: String) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(size)|\(modified)|\(label)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return cacheFolder.appendingPathComponent("\(digest).\(ext)")
    }

    private static func openIfUsable(_ url: URL) -> AVAudioFile? {
        guard let file = try? AVAudioFile(forReading: url), isUsable(file) else { return nil }
        // Touch it so the least recently played copies are the ones pruned.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return file
    }

    /// Opens the file under the extension its contents call for.
    private static func openRenamed(_ url: URL, data: Data, skipping: Int, ext: String) -> AVAudioFile? {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheFolder, withIntermediateDirectories: true)

        if skipping == 0 {
            // Cheapest first: a correctly-named link costs no storage.
            let link = cacheURL(for: url, label: "link", ext: ext)
            try? fm.removeItem(at: link)
            if (try? fm.createSymbolicLink(at: link, withDestinationURL: url)) != nil,
               let file = try? AVAudioFile(forReading: link), isUsable(file) {
                return file
            }
            try? fm.removeItem(at: link)
        }

        let copy = cacheURL(for: url, label: "copy\(skipping)", ext: ext)
        if let file = openIfUsable(copy) { return file }
        do {
            try data.subdata(in: (data.startIndex + skipping)..<data.endIndex).write(to: copy, options: .atomic)
        } catch {
            return nil
        }
        prune()
        if let file = openIfUsable(copy) { return file }
        try? fm.removeItem(at: copy)
        return nil
    }

    /// Plays a copy that starts exactly at the first MP3 frame.
    private static func openTrimmedMP3(_ url: URL, data: Data, from offset: Int) -> AVAudioFile? {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheFolder, withIntermediateDirectories: true)

        let copy = cacheURL(for: url, label: "mp3@\(offset)", ext: "mp3")
        if let file = openIfUsable(copy) { return file }

        // Drop a trailing ID3v1 block too; some damaged files carry several.
        var end = data.count
        while end - offset > 128,
              data[data.startIndex + end - 128] == 0x54,
              data[data.startIndex + end - 127] == 0x41,
              data[data.startIndex + end - 126] == 0x47 {
            end -= 128
        }
        guard end > offset else { return nil }
        do {
            try data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)).write(to: copy, options: .atomic)
        } catch {
            return nil
        }
        prune()
        if let file = openIfUsable(copy) { return file }
        try? fm.removeItem(at: copy)
        return nil
    }

    /// Keeps the repaired copies under the size limit, oldest out first.
    private static func prune() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let items = try? fm.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: keys) else { return }

        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for item in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            files.append((item, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > cacheLimitBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: file.url)
            total -= file.size
            if total <= cacheLimitBytes { break }
        }
    }

    // MARK: - Format check

    /// A file the engine can actually connect, schedule and decode.
    private static func isUsable(_ file: AVAudioFile) -> Bool {
        let format = file.processingFormat
        guard format.sampleRate > 0, format.sampleRate.isFinite, format.channelCount > 0 else { return false }
        if format.channelCount > 2 && format.channelLayout == nil { return false }
        guard file.length > 0 else { return false }

        // Opening is not proof: iOS will open some files it then cannot
        // decode a single sample of. Read a sliver to find out now, while the
        // file can still be repaired or reported, instead of discovering it as
        // silence.
        guard let probe = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return false }
        do {
            try file.read(into: probe, frameCount: 4096)
        } catch {
            return false
        }
        file.framePosition = 0
        return probe.frameLength > 0
    }
}
