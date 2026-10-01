//
//  LRCLibLookup.swift
//  Sonora
//
//  Lyrics from LRCLIB (lrclib.net): a free, open, key-less lyrics database.
//  Sonora stores unsynchronised lyrics, so plain lyrics are used; when an
//  entry only has synced (LRC) lyrics the timestamps are stripped.
//
//  Only ever called when the user taps "Find lyrics online".
//

import Foundation

struct OnlineLyrics: Identifiable, Equatable {
    let id = UUID()
    var trackName: String
    var artistName: String
    var albumName: String
    var duration: TimeInterval?
    var isInstrumental: Bool
    /// Plain text, ready for the lyrics tag. Empty for instrumentals.
    var text: String
    var source: String { "LRCLIB" }
}

enum LRCLibLookup {

    private struct Entry: Decodable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Best lyrics for a song. Tries the exact-match endpoint first (needs
    /// artist + title, and uses album and duration when known), then search.
    static func find(artist: String, title: String, album: String, duration: TimeInterval?) async throws -> OnlineLyrics {
        let a = LookupText.isPlaceholder(artist) ? "" : LookupText.clean(artist)
        let t = LookupText.clean(title)
        guard !t.isEmpty else { throw TagLookupError.emptyQuery }

        // 1. Exact match. LRCLIB matches duration within ±2 s.
        if !a.isEmpty {
            var items = [("artist_name", a), ("track_name", t)]
            if !LookupText.isPlaceholder(album) { items.append(("album_name", LookupText.clean(album))) }
            if let duration, duration.isFinite, duration > 0 {
                items.append(("duration", String(Int(duration.rounded()))))
            }
            if let url = LookupHTTP.url("https://lrclib.net/api/get", items) {
                let (data, status) = try await LookupHTTP.get(url, timeout: 9)
                if status == 200,
                   let entry = try? JSONDecoder().decode(Entry.self, from: data),
                   let lyrics = lyrics(from: entry) {
                    return lyrics
                }
                // 404 = no exact match; anything else falls through to search too.
            }
        }

        // 2. Search, then pick the closest entry.
        var items = [("track_name", t)]
        if !a.isEmpty { items.append(("artist_name", a)) }
        guard let url = LookupHTTP.url("https://lrclib.net/api/search", items) else { throw TagLookupError.badResponse }
        var entries = try await LookupHTTP.json([Entry].self, from: url)
        if entries.isEmpty, !a.isEmpty,
           let loose = LookupHTTP.url("https://lrclib.net/api/search", [("q", "\(a) \(t)")]) {
            entries = try await LookupHTTP.json([Entry].self, from: loose)
        }
        guard let best = best(in: entries, artist: a, title: t, duration: duration),
              let lyrics = lyrics(from: best) else {
            throw TagLookupError.noResults
        }
        return lyrics
    }

    private static func best(in entries: [Entry], artist: String, title: String, duration: TimeInterval?) -> Entry? {
        let wantTitle = LookupText.normalise(LookupText.strippingEditionSuffixes(title))
        let wantArtist = LookupText.normalise(artist)
        var best: (entry: Entry, score: Int)?
        for entry in entries {
            let hasText = !LookupText.clean(entry.plainLyrics).isEmpty
                || !LookupText.clean(entry.syncedLyrics).isEmpty
            guard hasText || entry.instrumental == true else { continue }

            let gotTitle = LookupText.normalise(LookupText.strippingEditionSuffixes(entry.trackName ?? ""))
            var score = 0
            if gotTitle == wantTitle { score += 4 }
            else if !gotTitle.isEmpty, gotTitle.contains(wantTitle) || wantTitle.contains(gotTitle) { score += 2 }
            else { continue }   // the title has to match

            let gotArtist = LookupText.normalise(entry.artistName ?? "")
            if !wantArtist.isEmpty {
                if gotArtist == wantArtist { score += 3 }
                else if !gotArtist.isEmpty, gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist) { score += 1 }
                else { continue }   // a same-named song by someone else is wrong
            }
            if let duration, duration > 0, let got = entry.duration, got > 0 {
                let diff = abs(got - duration)
                if diff <= 3 { score += 2 } else if diff > 20 { score -= 2 }
            }
            if hasText { score += 1 }
            if score > (best?.score ?? Int.min) { best = (entry, score) }
        }
        return best?.entry
    }

    private static func lyrics(from entry: Entry) -> OnlineLyrics? {
        let plain = LookupText.clean(entry.plainLyrics)
        let text = plain.isEmpty ? stripTimestamps(entry.syncedLyrics ?? "") : plain
        let instrumental = entry.instrumental == true
        guard !text.isEmpty || instrumental else { return nil }
        return OnlineLyrics(trackName: entry.trackName ?? "",
                            artistName: entry.artistName ?? "",
                            albumName: entry.albumName ?? "",
                            duration: entry.duration,
                            isInstrumental: instrumental && text.isEmpty,
                            text: text)
    }

    /// "[01:02.34] line" -> "line"; LRC header tags ("[ar:…]") are dropped.
    static func stripTimestamps(_ lrc: String) -> String {
        var lines: [String] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var sawTag = false
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                sawTag = true
            }
            // Word-level timestamps "<00:01.23>" in enhanced LRC.
            if let regex = try? NSRegularExpression(pattern: "<\\d+:\\d+(?:[.:]\\d+)?>") {
                line = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            if sawTag && line.isEmpty {
                // Timestamped blank lines are stanza breaks; header tags vanish.
                if raw.range(of: "^\\s*\\[\\d", options: .regularExpression) != nil { lines.append("") }
                continue
            }
            lines.append(line)
        }
        // Collapse runs of blank lines and trim the ends.
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
