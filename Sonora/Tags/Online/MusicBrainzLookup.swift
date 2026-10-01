//
//  MusicBrainzLookup.swift
//  Sonora
//
//  MusicBrainz (open music encyclopedia) for tags, and the Cover Art
//  Archive for its covers. Both free and key-less. MusicBrainz is the one
//  most likely to know rare, indie and local releases.
//
//  MusicBrainz asks every client to send a meaningful User-Agent and to
//  stay at or under one request per second; every call here goes through
//  MusicBrainzGate first.
//

import Foundation

enum MusicBrainzLookup {

    // MARK: - API model

    private struct ArtistCredit: Decodable {
        let name: String?
        let joinphrase: String?
    }

    private struct ReleaseGroup: Decodable {
        let id: String?
        let primaryType: String?
        let secondaryTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case id
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
        }
    }

    private struct Medium: Decodable {
        struct TrackRef: Decodable {
            let number: String?
            let position: Int?
        }
        let position: Int?
        let format: String?
        let track: [TrackRef]?
        let trackCount: Int?
        let trackOffset: Int?

        enum CodingKeys: String, CodingKey {
            case position, format, track
            case trackCount = "track-count"
            case trackOffset = "track-offset"
        }
    }

    private struct Release: Decodable {
        let id: String
        let title: String?
        let status: String?
        let date: String?
        let country: String?
        let artistCredit: [ArtistCredit]?
        let releaseGroup: ReleaseGroup?
        let trackCount: Int?
        let media: [Medium]?
        let score: Int?

        enum CodingKeys: String, CodingKey {
            case id, title, status, date, country, media, score
            case artistCredit = "artist-credit"
            case releaseGroup = "release-group"
            case trackCount = "track-count"
        }
    }

    private struct Tag: Decodable {
        let name: String?
        let count: Int?
    }

    private struct Recording: Decodable {
        let id: String
        let title: String?
        let length: Int?
        let score: Int?
        let artistCredit: [ArtistCredit]?
        let firstReleaseDate: String?
        let releases: [Release]?
        let tags: [Tag]?

        enum CodingKeys: String, CodingKey {
            case id, title, length, score, releases, tags
            case artistCredit = "artist-credit"
            case firstReleaseDate = "first-release-date"
        }
    }

    private struct RecordingPage: Decodable {
        let recordings: [Recording]?
    }

    private struct ReleasePage: Decodable {
        let releases: [Release]?
    }

    // MARK: - Song search

    static func searchSongs(term: String, hint: LookupHint?, limit: Int = 12) async throws -> [TagLookupCandidate] {
        guard let query = recordingQuery(term: term, hint: hint) else { throw TagLookupError.emptyQuery }
        let page = try await get(RecordingPage.self, "https://musicbrainz.org/ws/2/recording",
                                 [("query", query), ("fmt", "json"), ("limit", String(max(1, min(limit, 25))))])
        return (page.recordings ?? []).compactMap(candidate(from:))
    }

    /// Lucene query. Fielded when we know the title (precise); otherwise the
    /// raw text, which MusicBrainz matches against the recording title.
    private static func recordingQuery(term: String, hint: LookupHint?) -> String? {
        if let hint, !LookupText.clean(hint.title).isEmpty {
            var parts = ["recording:\(LookupText.quoted(hint.title))"]
            if !LookupText.isPlaceholder(hint.artist) {
                parts.append("artist:\(LookupText.quoted(hint.artist))")
            }
            return parts.joined(separator: " AND ")
        }
        // "Artist - Title" typed by the user splits nicely.
        let cleaned = LookupText.clean(term)
        guard !cleaned.isEmpty else { return nil }
        if let dash = cleaned.range(of: " - ") {
            let artist = String(cleaned[..<dash.lowerBound])
            let title = String(cleaned[dash.upperBound...])
            if !LookupText.clean(artist).isEmpty, !LookupText.clean(title).isEmpty {
                return "recording:\(LookupText.quoted(title)) AND artist:\(LookupText.quoted(artist))"
            }
        }
        // Lucene special characters would make the query invalid.
        let special = CharacterSet(charactersIn: "+-&|!(){}[]^\"~*?:\\/")
        return cleaned.components(separatedBy: special).joined(separator: " ")
    }

    private static func candidate(from recording: Recording) -> TagLookupCandidate? {
        let title = LookupText.clean(recording.title)
        guard !title.isEmpty else { return nil }
        let artist = credit(recording.artistCredit)
        let release = bestRelease(recording.releases ?? [])

        var trackNumber: Int?
        var discNumber: Int?
        var trackCount = LookupText.positive(release?.trackCount)
        if let medium = release?.media?.first {
            if let number = medium.track?.first?.number, let n = Int(number) {
                trackNumber = LookupText.positive(n)
            } else if let offset = medium.trackOffset {
                trackNumber = LookupText.positive(offset + 1)
            }
            // Multi-disc releases: count and number refer to this disc.
            if let discs = release?.media, discs.count > 1 || (medium.position ?? 1) > 1 {
                discNumber = LookupText.positive(medium.position)
                trackCount = LookupText.positive(medium.trackCount) ?? trackCount
            }
        }

        let albumArtist = credit(release?.artistCredit)
        let genre = (recording.tags ?? [])
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            .map { LookupText.clean($0.name) }
            .first { !$0.isEmpty }
            .map { $0.capitalized } ?? ""

        let covers = release.map { coverURLs(releaseID: $0.id, releaseGroupID: $0.releaseGroup?.id) }
        return TagLookupCandidate(title: title,
                                  artist: artist,
                                  album: LookupText.clean(release?.title),
                                  albumArtist: albumArtist.isEmpty ? artist : albumArtist,
                                  genre: genre,
                                  year: LookupText.year(from: release?.date) ?? LookupText.year(from: recording.firstReleaseDate),
                                  trackNumber: trackNumber,
                                  trackCount: trackCount,
                                  discNumber: discNumber,
                                  artworkURL100: covers?.thumbnail,
                                  artworkURL600: covers?.large,
                                  source: .musicbrainz,
                                  duration: recording.length.flatMap { $0 > 0 ? TimeInterval($0) / 1000 : nil },
                                  artworkFallbackURL: covers?.fallback,
                                  musicBrainzReleaseID: release?.id)
    }

    /// The release a tagger would want: official studio album first, then
    /// singles/EPs, compilations last; earliest date wins ties.
    private static func bestRelease(_ releases: [Release]) -> Release? {
        func rank(_ r: Release) -> Int {
            var score = 0
            if (r.status ?? "").lowercased() == "official" { score += 4 }
            switch (r.releaseGroup?.primaryType ?? "").lowercased() {
            case "album": score += 3
            case "ep", "single": score += 2
            default: break
            }
            if !(r.releaseGroup?.secondaryTypes ?? []).isEmpty { score -= 3 }   // compilation, live…
            return score
        }
        return releases.min { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra > rb }
            let da = (a.date ?? "").isEmpty ? "9999" : (a.date ?? "")
            let db = (b.date ?? "").isEmpty ? "9999" : (b.date ?? "")
            return da < db
        }
    }

    private static func credit(_ credits: [ArtistCredit]?) -> String {
        guard let credits, !credits.isEmpty else { return "" }
        return credits.map { ($0.name ?? "") + ($0.joinphrase ?? "") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Covers (Cover Art Archive)

    /// Releases for `artist` + `album`, best first.
    struct ReleaseMatch {
        var releaseID: String
        var releaseGroupID: String?
        var album: String
        var artist: String
        var year: Int?
        var trackCount: Int?
        var mbScore: Int
    }

    static func searchReleases(artist: String, album: String, limit: Int = 10) async throws -> [ReleaseMatch] {
        let cleanAlbum = LookupText.clean(album)
        guard !LookupText.isPlaceholder(cleanAlbum) else { return [] }
        var query = "release:\(LookupText.quoted(cleanAlbum))"
        if !LookupText.isPlaceholder(artist) {
            query += " AND artist:\(LookupText.quoted(artist))"
        }
        let page = try await get(ReleasePage.self, "https://musicbrainz.org/ws/2/release",
                                 [("query", query), ("fmt", "json"), ("limit", String(limit))])
        return (page.releases ?? []).map { r in
            ReleaseMatch(releaseID: r.id,
                         releaseGroupID: r.releaseGroup?.id,
                         album: LookupText.clean(r.title),
                         artist: credit(r.artistCredit),
                         year: LookupText.year(from: r.date),
                         trackCount: LookupText.positive(r.trackCount),
                         mbScore: r.score ?? 0)
        }
    }

    /// Cover-picker candidates: one per release group (releases of the same
    /// album usually share a cover), front-1200 with front-500 as fallback.
    static func searchCovers(artist: String, album: String) async throws -> [CoverCandidate] {
        let releases = try await searchReleases(artist: artist, album: album)
        var seenGroups = Set<String>()
        return releases.compactMap { r -> CoverCandidate? in
            let groupKey = r.releaseGroupID ?? r.releaseID
            guard seenGroups.insert(groupKey).inserted else { return nil }
            let urls = coverURLs(releaseID: r.releaseID, releaseGroupID: r.releaseGroupID)
            return CoverCandidate(source: .musicbrainz, album: r.album, artist: r.artist, year: r.year,
                                  thumbnailURL: urls.thumbnail, fullURL: urls.large,
                                  fallbackURL: urls.fallback, sizeNote: "up to 1200 px")
        }
    }

    /// For a release found by search we don't know whether the release
    /// itself has art, so the large image comes from the release group
    /// (CAA picks that group's representative front cover).
    static func coverURLs(releaseID: String, releaseGroupID: String?) -> (thumbnail: URL?, large: URL, fallback: URL?) {
        let base = releaseGroupID.map { "https://coverartarchive.org/release-group/\($0)" }
            ?? "https://coverartarchive.org/release/\(releaseID)"
        // Force-unwrap is safe: the strings are built from fixed ASCII and
        // MusicBrainz ids (UUIDs).
        return (URL(string: "\(base)/front-250"), URL(string: "\(base)/front-1200")!, URL(string: "\(base)/front-500"))
    }

    /// Downloads a Cover Art Archive front cover: 1200 px, else 500 px.
    /// 404 means the release has no cover.
    static func downloadCover(releaseID: String, releaseGroupID: String?) async -> Data? {
        let urls = coverURLs(releaseID: releaseID, releaseGroupID: releaseGroupID)
        return try? await ITunesTagLookup.downloadArtwork(urls.large, fallback: urls.fallback)
    }

    // MARK: - Internals

    private static func get<T: Decodable>(_ type: T.Type, _ base: String, _ items: [(String, String)]) async throws -> T {
        guard let url = LookupHTTP.url(base, items) else { throw TagLookupError.badResponse }
        try await MusicBrainzGate.shared.waitTurn()
        let (data, status) = try await LookupHTTP.get(url, timeout: 10)
        switch status {
        case 200:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw TagLookupError.badResponse }
        case 503:
            // Rate-limited. Don't retry; the gate keeps us polite next time.
            throw TagLookupError.badResponse
        default:
            throw TagLookupError.badResponse
        }
    }
}
