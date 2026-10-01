//
//  DeezerLookup.swift
//  Sonora
//
//  Deezer's public catalogue API: no key, no account, HTTPS. Strong on
//  mainstream and European releases, with 1000 px covers.
//
//  Quirk: Deezer reports errors (quota, bad query, missing id) as HTTP 200
//  with a body of {"error": {...}}, so every response is checked for that.
//

import Foundation

enum DeezerLookup {

    // MARK: - API model

    private struct ErrorBody: Decodable {
        struct Info: Decodable {
            let type: String?
            let message: String?
            let code: Int?
        }
        let error: Info?
    }

    private struct ArtistRef: Decodable {
        let name: String?
    }

    private struct AlbumRef: Decodable {
        let id: Int?
        let title: String?
        let cover_medium: String?
        let cover_big: String?
        let cover_xl: String?
        let release_date: String?
    }

    private struct TrackHit: Decodable {
        let id: Int?
        let title: String?
        let duration: Int?
        let artist: ArtistRef?
        let album: AlbumRef?
    }

    private struct AlbumHit: Decodable {
        let id: Int?
        let title: String?
        let cover_medium: String?
        let cover_xl: String?
        let nb_tracks: Int?
        let artist: ArtistRef?
    }

    private struct Page<T: Decodable>: Decodable {
        let data: [T]?
    }

    private struct TrackDetail: Decodable {
        let track_position: Int?
        let disk_number: Int?
        let release_date: String?
        let bpm: Double?
        let album: AlbumRef?
    }

    private struct AlbumDetail: Decodable {
        struct Genres: Decodable {
            struct Genre: Decodable { let name: String? }
            let data: [Genre]?
        }
        let title: String?
        let genres: Genres?
        let release_date: String?
        let nb_tracks: Int?
        let label: String?
        let cover_xl: String?
        let artist: ArtistRef?
    }

    // MARK: - Song search

    /// Song matches. With hints, an advanced `artist:"…" track:"…"` query is
    /// tried first and plain text is the fallback.
    static func searchSongs(term: String, hint: LookupHint?, limit: Int = 15) async throws -> [TagLookupCandidate] {
        var hits: [TrackHit] = []
        if let hint, !LookupText.clean(hint.title).isEmpty {
            var parts: [String] = []
            if !LookupText.isPlaceholder(hint.artist) { parts.append("artist:\(LookupText.quoted(hint.artist))") }
            parts.append("track:\(LookupText.quoted(hint.title))")
            hits = try await fetch(Page<TrackHit>.self,
                                   "https://api.deezer.com/search",
                                   [("q", parts.joined(separator: " ")), ("limit", String(limit))]).data ?? []
        }
        let cleaned = LookupText.clean(term)
        if hits.isEmpty, !cleaned.isEmpty {
            hits = try await fetch(Page<TrackHit>.self,
                                   "https://api.deezer.com/search",
                                   [("q", cleaned), ("limit", String(limit))]).data ?? []
        }
        return hits.compactMap { hit -> TagLookupCandidate? in
            let title = LookupText.clean(hit.title)
            guard !title.isEmpty else { return nil }
            let artist = LookupText.clean(hit.artist?.name)
            return TagLookupCandidate(title: title,
                                      artist: artist,
                                      album: LookupText.clean(hit.album?.title),
                                      albumArtist: artist,
                                      genre: "",
                                      year: LookupText.year(from: hit.album?.release_date),
                                      trackNumber: nil,
                                      trackCount: nil,
                                      discNumber: nil,
                                      artworkURL100: url(hit.album?.cover_medium),
                                      artworkURL600: url(hit.album?.cover_xl) ?? url(hit.album?.cover_big),
                                      source: .deezer,
                                      duration: hit.duration.flatMap { $0 > 0 ? TimeInterval($0) : nil },
                                      deezerTrackID: hit.id,
                                      deezerAlbumID: hit.album?.id)
        }
    }

    /// Search results lack track/disc numbers and genre. This fills them in
    /// from /track/{id} and /album/{id}; each half is optional, so a failure
    /// just leaves the candidate as it was.
    static func enrich(_ candidate: TagLookupCandidate) async -> TagLookupCandidate {
        var c = candidate
        var albumID = c.deezerAlbumID
        var trackDetail: TrackDetail?
        if let trackID = c.deezerTrackID {
            trackDetail = try? await fetch(TrackDetail.self, "https://api.deezer.com/track/\(trackID)", [])
        }
        if let detail = trackDetail {
            c.trackNumber = LookupText.positive(detail.track_position) ?? c.trackNumber
            c.discNumber = LookupText.positive(detail.disk_number) ?? c.discNumber
            c.year = LookupText.year(from: detail.release_date) ?? LookupText.year(from: detail.album?.release_date) ?? c.year
            if albumID == nil { albumID = detail.album?.id }
        }
        var albumDetail: AlbumDetail?
        if let albumID {
            albumDetail = try? await fetch(AlbumDetail.self, "https://api.deezer.com/album/\(albumID)", [])
        }
        if let album = albumDetail {
            if let genre = album.genres?.data?.map({ LookupText.clean($0.name) }).first(where: { !$0.isEmpty }) {
                c.genre = genre
            }
            c.trackCount = LookupText.positive(album.nb_tracks) ?? c.trackCount
            if c.year == nil { c.year = LookupText.year(from: album.release_date) }
            let albumArtist = LookupText.clean(album.artist?.name)
            if !albumArtist.isEmpty { c.albumArtist = albumArtist }
            let label = LookupText.clean(album.label)
            if !label.isEmpty { c.label = label }
            if let big = url(album.cover_xl) { c.artworkURL600 = big }
        }
        return c
    }

    // MARK: - Album / cover search

    struct AlbumMatch {
        var album: String
        var artist: String
        var trackCount: Int?
        var thumbnailURL: URL?
        var coverURL: URL
    }

    /// Albums for `artist` + `album`: advanced syntax first, plain text second.
    static func searchAlbums(artist: String, album: String, limit: Int = 10) async throws -> [AlbumMatch] {
        let cleanAlbum = LookupText.clean(album)
        guard !LookupText.isPlaceholder(cleanAlbum) else { return [] }
        let knownArtist = !LookupText.isPlaceholder(artist)

        var parts = ["album:\(LookupText.quoted(cleanAlbum))"]
        if knownArtist { parts.insert("artist:\(LookupText.quoted(artist))", at: 0) }
        var hits = try await fetch(Page<AlbumHit>.self,
                                   "https://api.deezer.com/search/album",
                                   [("q", parts.joined(separator: " ")), ("limit", String(limit))]).data ?? []
        if hits.isEmpty {
            let plain = [knownArtist ? LookupText.clean(artist) : "", cleanAlbum]
                .filter { !$0.isEmpty }.joined(separator: " ")
            hits = try await fetch(Page<AlbumHit>.self,
                                   "https://api.deezer.com/search/album",
                                   [("q", plain), ("limit", String(limit))]).data ?? []
        }
        return hits.compactMap { hit -> AlbumMatch? in
            guard let cover = url(hit.cover_xl) else { return nil }
            return AlbumMatch(album: LookupText.clean(hit.title),
                              artist: LookupText.clean(hit.artist?.name),
                              trackCount: LookupText.positive(hit.nb_tracks),
                              thumbnailURL: url(hit.cover_medium),
                              coverURL: cover)
        }
    }

    static func searchCovers(artist: String, album: String, fallbackTerm: String) async throws -> [CoverCandidate] {
        var matches = try await searchAlbums(artist: artist, album: album)
        if matches.isEmpty, !LookupText.clean(fallbackTerm).isEmpty {
            // No album name: covers of the albums the song appears on.
            let songs = try await searchSongs(term: fallbackTerm, hint: nil, limit: 10)
            matches = songs.compactMap { song -> AlbumMatch? in
                guard let cover = song.artworkURL600 else { return nil }
                return AlbumMatch(album: song.album, artist: song.artist, trackCount: nil,
                                  thumbnailURL: song.artworkURL100, coverURL: cover)
            }
        }
        var seen = Set<URL>()
        return matches.compactMap { m -> CoverCandidate? in
            guard seen.insert(m.coverURL).inserted else { return nil }
            return CoverCandidate(source: .deezer, album: m.album, artist: m.artist, year: nil,
                                  thumbnailURL: m.thumbnailURL ?? m.coverURL,
                                  fullURL: m.coverURL, fallbackURL: nil, sizeNote: "1000 px")
        }
    }

    // MARK: - Internals

    private static func fetch<T: Decodable>(_ type: T.Type, _ base: String, _ items: [(String, String)]) async throws -> T {
        guard let url = LookupHTTP.url(base, items) else { throw TagLookupError.badResponse }
        let (data, status) = try await LookupHTTP.get(url)
        guard status == 200 else { throw TagLookupError.badResponse }
        // HTTP 200 with {"error": {...}}.
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data), let error = body.error {
            // 800 = "no data" (unknown id / nothing found).
            if error.code == 800 { throw TagLookupError.noResults }
            throw TagLookupError.badResponse
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TagLookupError.badResponse
        }
    }

    private static func url(_ s: String?) -> URL? {
        guard let s, !s.isEmpty, s.hasPrefix("https://") || s.hasPrefix("http://") else { return nil }
        // Deezer's CDN serves the same paths over HTTPS.
        let secure: String = s.hasPrefix("http://") ? "https://" + String(s.dropFirst(7)) : s
        return URL(string: secure)
    }
}
