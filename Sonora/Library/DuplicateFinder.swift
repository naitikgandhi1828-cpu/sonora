//
//  DuplicateFinder.swift
//  Sonora
//
//  Works out which songs in the library are the same song stored twice.
//
//  Three outcomes for any two songs:
//    • clearly the same  → merged without asking
//    • clearly different → left alone
//    • not sure          → Sonora asks, and remembers the answer
//
//  "Merged" never deletes anything. The better-quality file stays in the
//  library and the other copies are simply hidden behind it; they can be
//  separated again at any time.
//
//  Everything here is plain value code with no access to the library, so it
//  is easy to reason about and cannot change anything by itself.
//

import Foundation

// MARK: - What Sonora remembers

/// Why Sonora is not sure two songs are the same.
enum DuplicateDoubt: String, Codable, CaseIterable, Identifiable {
    case differentAlbum
    case differentLength
    case versionLabel
    case artistSpelling
    case missingArtist
    case sameAlbumTwice

    var id: String { rawValue }

    /// Short title for the question.
    var headline: String {
        switch self {
        case .differentAlbum:  return "Same song on two albums"
        case .differentLength: return "Same song, slightly different length"
        case .versionLabel:    return "Same song with an extra label"
        case .artistSpelling:  return "Artist written differently"
        case .missingArtist:   return "Artist missing"
        case .sameAlbumTwice:  return "Twice on the same album"
        }
    }

    /// One sentence saying what matches and what does not.
    var explanation: String {
        switch self {
        case .differentAlbum:
            return "The title, artist and length match, but the album is different."
        case .differentLength:
            return "The title and artist match, but one file is a few seconds longer."
        case .versionLabel:
            return "One title has an extra note, such as “Remastered” or “From …”."
        case .artistSpelling:
            return "The main artist matches, but the artist line is not written the same way."
        case .missingArtist:
            return "The title and length match, but the artist is missing on at least one file."
        case .sameAlbumTwice:
            return "Both are on the same album, with different track numbers."
        }
    }

    /// Label for the "do the same next time" switch and the remembered rule.
    var similarCases: String {
        switch self {
        case .differentAlbum:  return "songs that differ only by album"
        case .differentLength: return "songs that differ only by a few seconds"
        case .versionLabel:    return "songs that differ only by a label in the title"
        case .artistSpelling:  return "songs where only the artist line is written differently"
        case .missingArtist:   return "songs where the artist is missing"
        case .sameAlbumTwice:  return "songs that appear twice on one album"
        }
    }
}

enum DuplicateAnswer: String, Codable {
    case merge
    case separate
}

/// The user's choices, kept between launches.
///
/// Answers are stored against what the songs *are* (title, artist, album,
/// length), not against file paths, so they still apply after a file is
/// moved, downloaded again or the library is rescanned.
struct DuplicateMemory: Codable, Equatable {
    /// Master switch: when off, nothing is merged and nothing is asked.
    var enabled: Bool = true
    /// Answers for one particular pair of songs. Key: `DuplicateFinder.pairKey`.
    var pairs: [String: DuplicateAnswer] = [:]
    /// "Always do this" answers for a whole kind of doubt. Key: `DuplicateDoubt.rawValue`.
    var rules: [String: DuplicateAnswer] = [:]
}

/// Something Sonora wants to ask about.
struct DuplicateQuestion: Identifiable, Hashable {
    /// The pair key the answer is remembered under.
    let id: String
    let doubt: DuplicateDoubt
    let first: UUID
    let second: UUID
}

/// One song that has other copies hidden behind it.
struct MergedSongGroup: Identifiable, Hashable {
    var id: UUID { keeper }
    /// The copy shown in the library (the best quality one).
    let keeper: UUID
    /// The hidden copies.
    let copies: [UUID]
}

// MARK: - A song, reduced to what matters for comparing

struct SongKey: Hashable {
    /// Title in lower case without accents, punctuation or "feat. …".
    var title: String
    /// `title` with notes such as "(Remastered 2011)" or "(From …)" removed too.
    var looseTitle: String
    var artist: String
    /// The first artist when several are listed.
    var primaryArtist: String
    /// "" when the album is unknown.
    var album: String
    var hasArtist: Bool
}

enum DuplicateFinder {

    /// The raw text a `SongKey` is made from; used to cache the keys.
    struct RawTags: Hashable {
        let title: String
        let artist: String
        let albumArtist: String
        let album: String
        let fileName: String
    }

    struct Result {
        /// Indices into the analysed list. Each group has two or more songs
        /// and starts with the one to keep.
        var groups: [[Int]] = []
        var questions: [DuplicateQuestion] = []
    }

    // MARK: Patterns

    // Optional on purpose: a pattern the system refuses must only switch that
    // clean-up step off, never crash the app.
    private static func pattern(_ text: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: text, options: [.caseInsensitive])
    }

    private static let featInBrackets = pattern(#"\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring|with)\s+[^\)\]]*[\)\]]"#)
    private static let featAtEnd = pattern(#"\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#)
    private static let anyBrackets = pattern(#"\s*[\(\[]([^\)\]]*)[\)\]]"#)
    private static let dashEnding = pattern(#"\s+[\-–—]\s+([^\-–—]*)$"#)
    private static let titleLabel = pattern(
        #"^\s*(?:from\b.*|.*\bremaster(?:ed)?\b.*|(?:album|single|original|radio|full|lp|ep) version|original(?: mix)?|explicit|clean|stereo|mono|deluxe.*|bonus track|full song|full audio|official.*|audio|lyrics?|lyrical(?: video)?|hq|hd|\d{2,3} ?kbps)\s*$"#)
    private static let albumLabel = pattern(
        #"^.*\b(?:deluxe|remaster(?:ed)?|edition|version|expanded|bonus|soundtrack|ost|anniversary|explicit|clean)\b.*$"#)
    private static let leadingNumber = pattern(#"^(?:\d{1,3}\s*[\.\-_]+\s*|0\d\s+)"#)
    private static let copyMarker = pattern(#"(?:\s*\(\d{1,2}\)|(?:\s+|\s*-\s*)copy(?: \d+)?)\s*$"#)
    private static let artistSeparator = pattern(#"\s*(?:,|;|/|&|\+|\band\b|\bwith\b|\bvs\.?)\s*"#)

    private static func fullRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private static func removing(_ regex: NSRegularExpression?, from text: String) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: "")
    }

    // Patterns are slow compared with a plain look at the text, and most
    // titles have nothing to remove. These quick tests skip the patterns
    // for them, which matters when a library has thousands of songs.
    private static func hasBrackets(_ text: String) -> Bool {
        text.utf8.contains { $0 == UInt8(ascii: "(") || $0 == UInt8(ascii: "[") }
    }

    /// True when `text` contains one of `words`, ignoring upper/lower case.
    /// The words must be plain lower-case ASCII.
    private static func containsAny(_ text: String, _ words: [[UInt8]]) -> Bool {
        let bytes = text.utf8.map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
        for word in words where !word.isEmpty && bytes.count >= word.count {
            var start = 0
            let last = bytes.count - word.count
            while start <= last {
                if bytes[start] == word[0] {
                    var offset = 1
                    while offset < word.count, bytes[start + offset] == word[offset] { offset += 1 }
                    if offset == word.count { return true }
                }
                start += 1
            }
        }
        return false
    }

    private static let featWords: [[UInt8]] = ["feat", "ft", "with "].map { Array($0.utf8) }
    private static let separatorWords: [[UInt8]] =
        [",", ";", "/", "&", "+", " and ", " with ", " vs"].map { Array($0.utf8) }

    private static func mayHaveFeat(_ text: String) -> Bool {
        containsAny(text, featWords)
    }

    private static func hasDash(_ text: String) -> Bool {
        // "-" in ASCII; the en and em dashes both start with byte 0xE2.
        text.utf8.contains { $0 == UInt8(ascii: "-") || $0 == 0xE2 }
    }

    /// "Song (feat. X)" and "Song feat. X" → "Song".
    private static func removingFeat(_ text: String) -> String {
        guard mayHaveFeat(text) else { return text }
        let inner = hasBrackets(text) ? removing(featInBrackets, from: text) : text
        return removing(featAtEnd, from: inner)
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: fullRange(text)) != nil
    }

    /// Removes "(…)" / "[…]" parts and a " - …" ending when what they say is
    /// only a label (as decided by `label`).
    private static func removingLabels(_ text: String, label: NSRegularExpression?) -> String {
        guard let anyBrackets, label != nil else { return text }
        var out = text
        if hasBrackets(text) {
            let working = NSMutableString(string: text)
            for match in anyBrackets.matches(in: text, range: fullRange(text)).reversed() {
                guard match.numberOfRanges > 1 else { continue }
                let inner = working.substring(with: match.range(at: 1))
                if matches(label, inner) { working.deleteCharacters(in: match.range) }
            }
            out = working as String
        }
        if hasDash(out), let dashEnding,
           let match = dashEnding.firstMatch(in: out, range: fullRange(out)),
           match.numberOfRanges > 1 {
            let ns = out as NSString
            if matches(label, ns.substring(with: match.range(at: 1))) {
                out = ns.substring(to: match.range.location)
            }
        }
        return out
    }

    /// Lower case, no accents, letters and digits only, single spaces.
    static func fold(_ text: String) -> String {
        // Plain English text (most tags) is handled byte by byte, which is
        // many times faster than the general route below.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var needSpace = false
        var isASCII = true
        for byte in text.utf8 {
            if byte >= 0x80 { isASCII = false; break }
            let lower = (byte >= 65 && byte <= 90) ? byte + 32 : byte
            if (lower >= 97 && lower <= 122) || (lower >= 48 && lower <= 57) {
                if needSpace, !bytes.isEmpty { bytes.append(32) }
                needSpace = false
                bytes.append(lower)
            } else {
                needSpace = true
            }
        }
        if isASCII { return String(decoding: bytes, as: UTF8.self) }

        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: nil)
        var out = ""
        out.reserveCapacity(folded.utf8.count)
        needSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if needSpace, !out.isEmpty { out.append(" ") }
                needSpace = false
                out.append(character)
            } else {
                needSpace = true
            }
        }
        return out
    }

    static func rawTags(of track: Track) -> RawTags {
        RawTags(title: track.title, artist: track.artist, albumArtist: track.albumArtist,
                album: track.album, fileName: track.fileName)
    }

    static func key(for raw: RawTags) -> SongKey {
        var title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            // No title tag: go by the file name, without "01 - " in front or
            // " (1)" / " copy" at the end.
            title = (raw.fileName as NSString).deletingPathExtension
            title = title.replacingOccurrences(of: "_", with: " ")
            title = removing(copyMarker, from: removing(leadingNumber, from: title))
        }
        let withoutFeat = removingFeat(title)
        let strict = fold(withoutFeat)
        let unlabelled = removingLabels(withoutFeat, label: titleLabel)
        var loose = unlabelled == withoutFeat ? strict : fold(unlabelled)
        if loose.isEmpty { loose = strict }

        let rawArtist = raw.artist.isEmpty ? raw.albumArtist : raw.artist
        let artistText = removingFeat(rawArtist)
        let artist = fold(artistText)
        let hasArtist = !artist.isEmpty && artist != "unknown artist" && artist != "unknown"
            && artist != "various artists" && artist != "various"

        var primary = artist
        // Only looked at when something that separates artists is there.
        if containsAny(artistText, separatorWords), let artistSeparator {
            let ns = artistText as NSString
            if let first = artistSeparator.firstMatch(in: artistText, range: fullRange(artistText)),
               first.range.location > 0 {
                let head = fold(ns.substring(to: first.range.location))
                if !head.isEmpty { primary = head }
            }
        }

        let album = fold(removingLabels(raw.album, label: albumLabel))
        let albumKnown = !album.isEmpty && album != "unknown album" && album != "unknown"

        return SongKey(title: strict,
                       looseTitle: loose,
                       artist: hasArtist ? artist : "",
                       primaryArtist: hasArtist ? primary : "",
                       album: albumKnown ? album : "",
                       hasArtist: hasArtist)
    }

    // MARK: Remembering

    /// What a song "is", for remembering answers about it.
    static func signature(_ key: SongKey, duration: TimeInterval) -> String {
        let seconds = duration.isFinite && duration >= 0 && duration < 1e9 ? Int(duration.rounded()) : 0
        return [key.title, key.artist, key.album, String(seconds)].joined(separator: "\u{1F}")
    }

    static func pairKey(_ a: String, _ b: String) -> String {
        a <= b ? a + "\u{1E}" + b : b + "\u{1E}" + a
    }

    // MARK: Comparing two songs

    private enum Verdict {
        case different
        case same
        case unsure(DuplicateDoubt)
    }

    private static func compare(_ a: Track, _ ka: SongKey, _ b: Track, _ kb: SongKey) -> Verdict {
        let gap = abs(a.duration - b.duration)
        guard gap.isFinite, gap <= 8 else { return .different }

        // The very same file copied twice.
        if a.fileSize > 0, a.fileSize == b.fileSize, gap < 0.05,
           a.fileExtension.lowercased() == b.fileExtension.lowercased() {
            return .same
        }

        let sameTitle = ka.title == kb.title

        if !ka.hasArtist || !kb.hasArtist {
            if ka.hasArtist != kb.hasArtist {
                return gap <= 2 ? .unsure(.missingArtist) : .different
            }
            return sameTitle && gap <= 1 ? .unsure(.missingArtist) : .different
        }

        // Two different artists: a cover, not a copy.
        guard ka.primaryArtist == kb.primaryArtist else { return .different }

        if !sameTitle {
            return gap <= 3 ? .unsure(.versionLabel) : .different
        }
        if gap > 2 { return .unsure(.differentLength) }
        if ka.artist != kb.artist { return .unsure(.artistSpelling) }

        if ka.album == kb.album || ka.album.isEmpty || kb.album.isEmpty {
            if !ka.album.isEmpty, ka.album == kb.album,
               let na = a.trackNumber, let nb = b.trackNumber,
               na != nb || (a.discNumber ?? 1) != (b.discNumber ?? 1) {
                return .unsure(.sameAlbumTwice)
            }
            return .same
        }
        return .unsure(.differentAlbum)
    }

    // MARK: Choosing which copy to keep

    private static let losslessExtensions: Set<String> = ["flac", "alac", "wav", "wave", "aif", "aiff", "aifc"]

    private static func isLossless(_ t: Track) -> Bool {
        t.bitDepth != nil || losslessExtensions.contains(t.fileExtension.lowercased())
    }

    private static func qualityNumber(_ t: Track) -> Double {
        if isLossless(t) {
            let rate = t.sampleRate.isFinite ? t.sampleRate : 0
            return rate * Double(t.bitDepth ?? 16)
        }
        if let kbps = t.bitrate, kbps > 0 { return Double(kbps) }
        guard t.duration.isFinite, t.duration > 1, t.fileSize > 0 else { return 0 }
        return Double(t.fileSize) * 8 / t.duration / 1000
    }

    private static func tagScore(_ t: Track) -> Int {
        var score = 0
        if !t.title.isEmpty { score += 1 }
        if !t.artist.isEmpty { score += 1 }
        if !t.album.isEmpty { score += 1 }
        if !t.genre.isEmpty { score += 1 }
        if t.year != nil { score += 1 }
        if t.trackNumber != nil { score += 1 }
        return score
    }

    /// True when `a` is the better copy to keep.
    static func isBetter(_ a: Track, than b: Track) -> Bool {
        let playableA = AudioFormats.isPlayable(a.fileExtension)
        let playableB = AudioFormats.isPlayable(b.fileExtension)
        if playableA != playableB { return playableA }

        let losslessA = isLossless(a), losslessB = isLossless(b)
        if losslessA != losslessB { return losslessA }

        let qa = qualityNumber(a), qb = qualityNumber(b)
        // Ignore tiny differences (two encodes reported as 319 and 320 kbps).
        if abs(qa - qb) > max(qa, qb) * 0.03 { return qa > qb }

        if a.hasEmbeddedArtwork != b.hasEmbeddedArtwork { return a.hasEmbeddedArtwork }
        let ta = tagScore(a), tb = tagScore(b)
        if ta != tb { return ta > tb }
        let lyricsA = !(a.lyrics ?? "").isEmpty, lyricsB = !(b.lyrics ?? "").isEmpty
        if lyricsA != lyricsB { return lyricsA }
        if (a.rootID != nil) != (b.rootID != nil) { return a.rootID != nil }
        if a.dateAdded != b.dateAdded { return a.dateAdded < b.dateAdded }
        // Last resort, so the choice is the same every time.
        return (a.relativePath, a.id.uuidString) < (b.relativePath, b.id.uuidString)
    }

    // MARK: The whole library

    /// `keys[i]` must be the `SongKey` of `tracks[i]`.
    static func analyse(tracks: [Track], keys: [SongKey], memory: DuplicateMemory) -> Result {
        var result = Result()
        guard memory.enabled, tracks.count > 1, tracks.count == keys.count else { return result }

        // Only songs with the same (loose) title can be the same song.
        var buckets: [String: [Int]] = [:]
        for (i, track) in tracks.enumerated() {
            // A cue-sheet track is a slice of a longer file, not a file.
            guard !track.isCueTrack, track.duration.isFinite, track.duration > 0,
                  !keys[i].looseTitle.isEmpty else { continue }
            buckets[keys[i].looseTitle, default: []].append(i)
        }

        var parent = Array(tracks.indices)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var node = x
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var signatures: [Int: String] = [:]
        func signatureOf(_ i: Int) -> String {
            if let known = signatures[i] { return known }
            let made = signature(keys[i], duration: tracks[i].duration)
            signatures[i] = made
            return made
        }

        var open: [(Int, Int, DuplicateDoubt, String)] = []

        for (_, members) in buckets where members.count > 1 {
            // Sorted by length, so each song is only compared with the few
            // that are within 8 seconds of it.
            let sorted = members.sorted { tracks[$0].duration < tracks[$1].duration }
            for x in 0..<sorted.count {
                let i = sorted[x]
                var y = x + 1
                while y < sorted.count, tracks[sorted[y]].duration - tracks[i].duration <= 8 {
                    let j = sorted[y]
                    y += 1
                    let verdict = compare(tracks[i], keys[i], tracks[j], keys[j])
                    if case .different = verdict { continue }

                    let pair = pairKey(signatureOf(i), signatureOf(j))
                    // What the user said about these two wins over everything.
                    if let answer = memory.pairs[pair] {
                        if answer == .merge { union(i, j) }
                        continue
                    }
                    switch verdict {
                    case .same:
                        union(i, j)
                    case .unsure(let doubt):
                        if let rule = memory.rules[doubt.rawValue] {
                            if rule == .merge { union(i, j) }
                        } else {
                            open.append((i, j, doubt, pair))
                        }
                    case .different:
                        break
                    }
                }
            }
        }

        // Groups, best copy first.
        var byRoot: [Int: [Int]] = [:]
        for i in tracks.indices { byRoot[find(i), default: []].append(i) }
        for (_, members) in byRoot where members.count > 1 {
            result.groups.append(members.sorted { isBetter(tracks[$0], than: tracks[$1]) })
        }
        // A steady order, so the published list does not shuffle each time.
        result.groups.sort {
            tracks[$0[0]].displayTitle.lowercased() < tracks[$1[0]].displayTitle.lowercased()
        }

        // Questions: only between songs that are still apart, one per pair
        // of groups, one per remembered key.
        var askedGroups = Set<String>()
        var askedKeys = Set<String>()
        for (i, j, doubt, pair) in open {
            let ri = find(i), rj = find(j)
            guard ri != rj else { continue }
            let groupPair = "\(min(ri, rj))-\(max(ri, rj))"
            guard askedGroups.insert(groupPair).inserted, askedKeys.insert(pair).inserted else { continue }
            result.questions.append(DuplicateQuestion(id: pair, doubt: doubt,
                                                      first: tracks[i].id, second: tracks[j].id))
        }
        result.questions.sort { $0.id < $1.id }
        return result
    }
}
