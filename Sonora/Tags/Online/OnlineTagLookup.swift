//
//  OnlineTagLookup.swift
//  Sonora
//
//  Asks every enabled catalogue at once, tolerates any of them failing or
//  being slow, and merges what comes back into one ranked, de-duplicated
//  list. Used by the tag editor's Auto-fill and cover picker.
//

import Foundation

enum OnlineTagLookup {

    private typealias SongOutcome = (LookupSource, Result<[TagLookupCandidate], Error>)
    private typealias CoverOutcome = (LookupSource, Result<[CoverCandidate], Error>)

    /// Per-source deadline for a merged search. MusicBrainz gets longer
    /// because its requests may queue behind the one-per-second gate.
    private static func deadline(for source: LookupSource) -> Double {
        source == .musicbrainz ? 14 : 10
    }

    struct SongResults {
        /// Every match, best first, not de-duplicated (so a per-source
        /// filter still shows each source's own results).
        var all: [TagLookupCandidate]
        /// Sources that failed, with a short reason.
        var failures: [LookupSource: String]

        func results(for source: LookupSource?) -> [TagLookupCandidate] {
            guard let source else { return OnlineTagLookup.deduplicated(all) }
            return all.filter { $0.source == source }
        }
    }

    // MARK: - Songs

    static func searchSongs(term: String,
                            hint: LookupHint?,
                            sources: [LookupSource]) async throws -> SongResults {
        let cleaned = LookupText.clean(term)
        guard !cleaned.isEmpty else { throw TagLookupError.emptyQuery }
        guard !sources.isEmpty else { throw TagLookupError.noResults }

        var lists: [LookupSource: [TagLookupCandidate]] = [:]
        var failures: [LookupSource: String] = [:]
        var firstError: Error?

        await withTaskGroup(of: SongOutcome.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let found = try await LookupHTTP.withDeadline(OnlineTagLookup.deadline(for: source)) {
                            try await OnlineTagLookup.songs(from: source, term: cleaned, hint: hint)
                        }
                        return (source, .success(found))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let found):
                    lists[source] = found
                case .failure(let error):
                    // "No results" from one source isn't a failure.
                    if let e = error as? TagLookupError, e == .noResults {
                        lists[source] = []
                    } else if !(error is CancellationError) {
                        failures[source] = error.localizedDescription
                        if firstError == nil { firstError = error }
                    }
                }
            }
        }
        try Task.checkCancellation()

        // Nothing answered at all: surface the error like the old iTunes-only
        // search did (offline, timed out…).
        if lists.isEmpty, let firstError { throw firstError }

        let queryTokens = LookupText.tokens(hint.map { "\($0.artist) \($0.title)" } ?? cleaned)
            .union(LookupText.tokens(cleaned))
        var ranked: [TagLookupCandidate] = []
        for list in lists.values {
            for (index, var item) in list.enumerated() {
                item.score = score(item, queryTokens: queryTokens, hint: hint, rank: index)
                ranked.append(item)
            }
        }
        ranked.sort { $0.score > $1.score }
        return SongResults(all: ranked, failures: failures)
    }

    private static func songs(from source: LookupSource, term: String, hint: LookupHint?) async throws -> [TagLookupCandidate] {
        switch source {
        case .itunes: return try await ITunesTagLookup.searchSongs(term: term)
        case .deezer: return try await DeezerLookup.searchSongs(term: term, hint: hint)
        case .musicbrainz: return try await MusicBrainzLookup.searchSongs(term: term, hint: hint)
        }
    }

    /// Fills in details a source only gives on a second request (Deezer's
    /// track/disc numbers and genre). Never throws; worst case unchanged.
    static func enrich(_ candidate: TagLookupCandidate) async -> TagLookupCandidate {
        switch candidate.source {
        case .deezer: return await DeezerLookup.enrich(candidate)
        case .itunes, .musicbrainz: return candidate
        }
    }

    /// Downloads a candidate's cover, trying the fallback size if needed.
    static func downloadCover(for candidate: TagLookupCandidate) async -> Data? {
        guard let url = candidate.artworkURL600 ?? candidate.artworkURL100 else { return nil }
        let fallback = candidate.artworkFallbackURL ?? (url == candidate.artworkURL100 ? nil : candidate.artworkURL100)
        return try? await ITunesTagLookup.downloadArtwork(url, fallback: fallback)
    }

    // MARK: - Ranking

    /// Higher is better. Mostly "how much of what the user typed does this
    /// result contain", with a bonus when the title itself is fully covered,
    /// a small penalty for appearing lower in its own source's list, and a
    /// tiny source tie-break.
    static func score(_ c: TagLookupCandidate, queryTokens: Set<String>, hint: LookupHint?, rank: Int) -> Double {
        guard !queryTokens.isEmpty else { return -Double(rank) }
        let titleTokens = LookupText.tokens(LookupText.strippingEditionSuffixes(c.title))
        let artistTokens = LookupText.tokens(c.artist).union(LookupText.tokens(c.albumArtist))
        let albumTokens = LookupText.tokens(c.album)
        let candidateTokens = titleTokens.union(artistTokens)

        let covered = Double(queryTokens.intersection(candidateTokens).count) / Double(queryTokens.count)
        var score = covered * 10

        // Title words all present in the query = this really is the song.
        if !titleTokens.isEmpty, titleTokens.isSubset(of: queryTokens.union(albumTokens)) { score += 3 }
        // Extra words in the result title ("Live", "Remix", "Karaoke") cost a bit.
        score -= Double(titleTokens.subtracting(queryTokens).count) * 0.6

        if let hint {
            let wantTitle = LookupText.normalise(LookupText.strippingEditionSuffixes(hint.title))
            let gotTitle = LookupText.normalise(LookupText.strippingEditionSuffixes(c.title))
            if !wantTitle.isEmpty, wantTitle == gotTitle { score += 3 }
            let wantArtist = LookupText.normalise(hint.artist)
            if !wantArtist.isEmpty, LookupText.normalise(c.artist) == wantArtist { score += 2 }
            let wantAlbum = LookupText.normalise(LookupText.strippingEditionSuffixes(hint.album))
            if !wantAlbum.isEmpty,
               LookupText.normalise(LookupText.strippingEditionSuffixes(c.album)) == wantAlbum { score += 1.5 }
        }
        // Words like "karaoke" / "tribute" are almost never what's wanted.
        let junk: Set<String> = ["karaoke", "tribute", "instrumental", "cover", "originally", "performed"]
        if !junk.isDisjoint(with: titleTokens.union(albumTokens).union(artistTokens).subtracting(queryTokens)) {
            score -= 4
        }
        score -= Double(rank) * 0.15
        score += c.source.tieBreak
        return score
    }

    /// Collapses the same song found in several catalogues (or twice in one)
    /// into the best-ranked entry, filling its blanks from the others and
    /// remembering where else it was found. Input must be sorted best first.
    static func deduplicated(_ items: [TagLookupCandidate]) -> [TagLookupCandidate] {
        var order: [String] = []
        var byKey: [String: TagLookupCandidate] = [:]
        for item in items {
            let key = [LookupText.normalise(LookupText.strippingEditionSuffixes(item.title)),
                       LookupText.normalise(item.artist),
                       LookupText.normalise(LookupText.strippingEditionSuffixes(item.album))]
                .joined(separator: "|")
            guard var kept = byKey[key] else {
                byKey[key] = item
                order.append(key)
                continue
            }
            if item.source != kept.source, !kept.alsoFoundIn.contains(item.source) {
                kept.alsoFoundIn.append(item.source)
            }
            if kept.genre.isEmpty { kept.genre = item.genre }
            if kept.year == nil { kept.year = item.year }
            if kept.trackNumber == nil { kept.trackNumber = item.trackNumber }
            if kept.trackCount == nil { kept.trackCount = item.trackCount }
            if kept.discNumber == nil { kept.discNumber = item.discNumber }
            if kept.artworkURL600 == nil {
                kept.artworkURL600 = item.artworkURL600
                kept.artworkURL100 = kept.artworkURL100 ?? item.artworkURL100
                kept.artworkFallbackURL = item.artworkFallbackURL
            }
            if kept.deezerTrackID == nil, item.source == .deezer {
                kept.deezerTrackID = item.deezerTrackID
                kept.deezerAlbumID = item.deezerAlbumID
            }
            byKey[key] = kept
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: - Covers

    struct CoverResults {
        var covers: [CoverCandidate]
        var failures: [LookupSource: String]
    }

    static func searchCovers(artist: String,
                             album: String,
                             fallbackTerm: String,
                             sources: [LookupSource]) async throws -> CoverResults {
        let wantAlbum = LookupText.clean(album)
        let wantArtist = LookupText.clean(artist)
        guard !LookupText.isPlaceholder(wantAlbum) || !LookupText.clean(fallbackTerm).isEmpty else {
            throw TagLookupError.emptyQuery
        }
        var lists: [LookupSource: [CoverCandidate]] = [:]
        var failures: [LookupSource: String] = [:]
        var firstError: Error?

        await withTaskGroup(of: CoverOutcome.self) { group in
            for source in sources {
                // MusicBrainz release search needs an album title.
                if source == .musicbrainz, LookupText.isPlaceholder(wantAlbum) { continue }
                group.addTask {
                    do {
                        let found = try await LookupHTTP.withDeadline(OnlineTagLookup.deadline(for: source)) {
                            try await OnlineTagLookup.covers(from: source, artist: wantArtist, album: wantAlbum, fallbackTerm: fallbackTerm)
                        }
                        return (source, .success(found))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                switch result {
                case .success(let found):
                    lists[source] = found
                case .failure(let error):
                    if let e = error as? TagLookupError, e == .noResults {
                        lists[source] = []
                    } else if !(error is CancellationError) {
                        failures[source] = error.localizedDescription
                        if firstError == nil { firstError = error }
                    }
                }
            }
        }
        try Task.checkCancellation()
        if lists.isEmpty, let firstError { throw firstError }

        let albumNorm = LookupText.normalise(LookupText.strippingEditionSuffixes(wantAlbum))
        let artistNorm = LookupText.isPlaceholder(wantArtist) ? "" : LookupText.normalise(wantArtist)
        var all: [CoverCandidate] = []
        for list in lists.values {
            for (index, var cover) in list.enumerated() {
                var s = 0.0
                let got = LookupText.normalise(LookupText.strippingEditionSuffixes(cover.album))
                if !albumNorm.isEmpty {
                    if got == albumNorm { s += 4 }
                    else if !got.isEmpty, got.hasPrefix(albumNorm) || albumNorm.hasPrefix(got) { s += 2 }
                }
                let gotArtist = LookupText.normalise(cover.artist)
                if !artistNorm.isEmpty {
                    if gotArtist == artistNorm { s += 3 }
                    else if !gotArtist.isEmpty, gotArtist.contains(artistNorm) || artistNorm.contains(gotArtist) { s += 1 }
                }
                s -= Double(index) * 0.2
                s += cover.source.tieBreak
                cover.score = s
                all.append(cover)
            }
        }
        all.sort { $0.score > $1.score }
        return CoverResults(covers: all, failures: failures)
    }

    private static func covers(from source: LookupSource, artist: String, album: String, fallbackTerm: String) async throws -> [CoverCandidate] {
        switch source {
        case .itunes:
            return try await ITunesTagLookup.searchCovers(artist: artist, album: album, fallbackTerm: fallbackTerm)
        case .deezer:
            return try await DeezerLookup.searchCovers(artist: artist, album: album, fallbackTerm: fallbackTerm)
        case .musicbrainz:
            return try await MusicBrainzLookup.searchCovers(artist: artist, album: album)
        }
    }

    static func downloadCover(_ cover: CoverCandidate) async throws -> Data {
        try await ITunesTagLookup.downloadArtwork(cover.fullURL, fallback: cover.fallbackURL)
    }
}
