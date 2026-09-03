//
//  PlaylistParsers.swift
//  Sonora
//
//  Cue sheet and M3U parsing.
//

import Foundation

// MARK: - Cue sheets

struct CueSheet {
    struct Entry {
        var number: Int
        var title: String
        var performer: String
        var startTime: TimeInterval
        var endTime: TimeInterval?
        var isrc: String?
    }

    var performer: String = ""
    var albumTitle: String = ""
    var genre: String = ""
    var date: String = ""
    /// Audio files referenced by the sheet, in order.
    var audioFileNames: [String] = []
    var entries: [Entry] = []
}

enum CueSheetParser {

    /// Parses a .cue file. Track end times are filled in from the next
    /// track's start; the final track is left open-ended.
    static func parse(contentsOf url: URL) -> CueSheet? {
        guard let raw = readText(at: url) else { return nil }
        return parse(text: raw)
    }

    static func parse(text: String) -> CueSheet {
        var sheet = CueSheet()
        var current: CueSheet.Entry?
        var inTrack = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()

            if upper.hasPrefix("FILE ") {
                if let name = firstQuoted(in: line) {
                    sheet.audioFileNames.append(name)
                } else {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2 { sheet.audioFileNames.append(String(parts[1])) }
                }
            } else if upper.hasPrefix("TRACK ") {
                if let c = current { sheet.entries.append(c) }
                let parts = line.split(separator: " ")
                let number = parts.count > 1 ? Int(parts[1]) ?? sheet.entries.count + 1 : sheet.entries.count + 1
                current = CueSheet.Entry(number: number, title: "", performer: sheet.performer, startTime: 0)
                inTrack = true
            } else if upper.hasPrefix("TITLE ") {
                let value = firstQuoted(in: line) ?? String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if inTrack { current?.title = value } else { sheet.albumTitle = value }
            } else if upper.hasPrefix("PERFORMER ") {
                let value = firstQuoted(in: line) ?? String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                if inTrack { current?.performer = value } else { sheet.performer = value }
            } else if upper.hasPrefix("REM GENRE ") {
                sheet.genre = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("REM DATE ") {
                sheet.date = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("ISRC ") {
                current?.isrc = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("INDEX 01 ") {
                let stamp = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                current?.startTime = parseTimestamp(stamp)
            }
        }
        if let c = current { sheet.entries.append(c) }

        // Fill end times from the following start time.
        for i in 0..<max(0, sheet.entries.count - 1) {
            sheet.entries[i].endTime = sheet.entries[i + 1].startTime
        }
        if sheet.entries.contains(where: { $0.performer.isEmpty }) {
            for i in sheet.entries.indices where sheet.entries[i].performer.isEmpty {
                sheet.entries[i].performer = sheet.performer
            }
        }
        return sheet
    }

    /// "MM:SS:FF" where FF is frames at 75 fps.
    static func parseTimestamp(_ s: String) -> TimeInterval {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 60 + parts[1] + parts[2] / 75.0
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    private static func firstQuoted(in line: String) -> String? {
        guard let start = line.firstIndex(of: "\"") else { return nil }
        let rest = line.index(after: start)
        guard let end = line[rest...].firstIndex(of: "\"") else { return nil }
        return String(line[rest..<end])
    }

    static func readText(at url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1, .windowsCP1252, .macOSRoman] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return nil
    }
}

// MARK: - M3U

struct M3UEntry {
    var path: String
    var title: String?
    var duration: TimeInterval?
}

enum M3UParser {

    static func parse(contentsOf url: URL) -> [M3UEntry] {
        guard let text = CueSheetParser.readText(at: url) else { return [] }
        return parse(text: text)
    }

    static func parse(text: String) -> [M3UEntry] {
        var entries: [M3UEntry] = []
        var pendingTitle: String?
        var pendingDuration: TimeInterval?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF:") {
                let payload = String(line.dropFirst(8))
                if let comma = payload.firstIndex(of: ",") {
                    pendingDuration = Double(payload[..<comma].trimmingCharacters(in: .whitespaces))
                    pendingTitle = String(payload[payload.index(after: comma)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if line.hasPrefix("#") { continue }

            entries.append(M3UEntry(path: line, title: pendingTitle, duration: pendingDuration))
            pendingTitle = nil
            pendingDuration = nil
        }
        return entries
    }

    static func write(_ tracks: [Track], name: String, resolver: (Track) -> String) -> String {
        var out = "#EXTM3U\n"
        for t in tracks {
            out += "#EXTINF:\(Int(t.duration.rounded())),\(t.displayArtist) - \(t.displayTitle)\n"
            out += resolver(t) + "\n"
        }
        return out
    }
}
