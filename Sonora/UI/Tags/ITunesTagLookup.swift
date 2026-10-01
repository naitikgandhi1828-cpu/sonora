//
//  ITunesTagLookup.swift
//  Sonora
//
//  Online lookups for the tag editor: song matches and album covers from
//  Apple's public iTunes Search API (no key, no account, HTTPS only).
//  The other catalogues (Deezer, MusicBrainz, LRCLIB) live in
//  Sonora/Tags/Online and are merged by OnlineTagLookup.
//
//  Same approach as ArtworkFinder: URLComponents for the query, a short
//  timeout, and the request carries nothing but the text the user sees in
//  the search field. Unlike ArtworkFinder's background lookups these only
//  ever run when the user taps a button in the editor.
//

import Foundation
import UIKit
import ImageIO

/// One song match, already reduced to the fields the tag editor fills.
struct TagLookupCandidate: Identifiable {
    let id = UUID()
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var genre: String
    var year: Int?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var artworkURL100: URL?
    /// The large cover: 600 px from iTunes, 1000 px from Deezer, 1200 px
    /// from the Cover Art Archive.
    var artworkURL600: URL?

    // Added for the multi-source lookup. All defaulted, so the iTunes code
    // above (and anything else using the memberwise initialiser) still works.

    /// Which catalogue this match came from.
    var source: LookupSource = .itunes
    /// Other catalogues that returned the same song (merged duplicates).
    var alsoFoundIn: [LookupSource] = []
    /// Song length in seconds, when the catalogue says.
    var duration: TimeInterval?
    /// Tried when `artworkURL600` fails (Cover Art Archive's smaller size).
    var artworkFallbackURL: URL?
    /// Deezer ids, used to fetch track/disc numbers and genre on pick.
    var deezerTrackID: Int?
    var deezerAlbumID: Int?
    /// MusicBrainz release id.
    var musicBrainzReleaseID: String?
    /// Record label, when known (shown only; there's no tag field for it).
    var label: String?
    /// Match quality against the query; higher is better.
    var score: Double = 0
}

/// One cover found online, for the tag editor's cover picker.
struct CoverCandidate: Identifiable {
    let id = UUID()
    var source: LookupSource
    var album: String
    var artist: String
    var year: Int?
    var thumbnailURL: URL?
    var fullURL: URL
    var fallbackURL: URL?
    /// "600 px", "1000 px", "up to 1200 px".
    var sizeNote: String
    var score: Double = 0
}

enum TagLookupError: LocalizedError {
    case offline
    case badResponse
    case noResults
    case emptyQuery
    case badImage
    case timedOut

    var errorDescription: String? {
        switch self {
        case .offline:
            return "You appear to be offline. Connect to the internet and try again."
        case .badResponse:
            return "The online catalogue didn't answer properly. Try again in a moment."
        case .timedOut:
            return "The online catalogue took too long to answer. Try again in a moment."
        case .noResults:
            return "No matches found. Try fewer or different words."
        case .emptyQuery:
            return "Type an artist and song title to search."
        case .badImage:
            return "The cover couldn't be downloaded."
        }
    }
}

enum ITunesTagLookup {

    // MARK: - API model

    private struct Response: Decodable {
        struct Item: Decodable {
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let collectionArtistName: String?
            let artworkUrl100: String?
            let releaseDate: String?
            let primaryGenreName: String?
            let trackNumber: Int?
            let trackCount: Int?
            let discNumber: Int?
        }
        let results: [Item]
    }

    // MARK: - Song search

    /// Searches for songs matching `term` (artist and/or title).
    static func searchSongs(term: String, limit: Int = 15) async throws -> [TagLookupCandidate] {
        let items = try await search(term: term, entity: "song", limit: limit)
        return items.compactMap { item -> TagLookupCandidate? in
            let title = (item.trackName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let artist = (item.artistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let collectionArtist = (item.collectionArtistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return TagLookupCandidate(title: title,
                                      artist: artist,
                                      album: item.collectionName ?? "",
                                      albumArtist: collectionArtist.isEmpty ? artist : collectionArtist,
                                      genre: item.primaryGenreName ?? "",
                                      year: year(from: item.releaseDate),
                                      trackNumber: positive(item.trackNumber),
                                      trackCount: positive(item.trackCount),
                                      discNumber: positive(item.discNumber),
                                      artworkURL100: item.artworkUrl100.flatMap { URL(string: $0) },
                                      artworkURL600: item.artworkUrl100.flatMap { largeArtworkURL($0) })
        }
    }

    // MARK: - Cover search

    /// Album covers for the cover picker: an album search on artist + album
    /// when an album name is known, else a song search on `fallbackTerm`.
    static func searchCovers(artist: String, album: String, fallbackTerm: String) async throws -> [CoverCandidate] {
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [Response.Item] = []
        if !LookupText.isPlaceholder(cleanAlbum) {
            let term = [LookupText.isPlaceholder(cleanArtist) ? "" : cleanArtist, cleanAlbum]
                .filter { !$0.isEmpty }.joined(separator: " ")
            items = try await search(term: term, entity: "album", limit: 10)
        }
        if items.isEmpty, !fallbackTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items = try await search(term: fallbackTerm, entity: "song", limit: 10)
        }
        var seen = Set<String>()
        return items.compactMap { item -> CoverCandidate? in
            guard let small = item.artworkUrl100, let thumb = URL(string: small),
                  seen.insert(small).inserted else { return nil }
            let full = largeArtworkURL(small) ?? thumb
            let artistName = (item.collectionArtistName ?? item.artistName ?? "")
            return CoverCandidate(source: .itunes,
                                  album: item.collectionName ?? "",
                                  artist: artistName,
                                  year: year(from: item.releaseDate),
                                  thumbnailURL: thumb,
                                  fullURL: full,
                                  fallbackURL: full == thumb ? nil : thumb,
                                  sizeNote: "600 px")
        }
    }

    /// Finds an album cover and returns it as JPEG data (at most 1200 px).
    /// Searches albums by artist + album when an album name is known,
    /// otherwise falls back to a song search on `fallbackTerm`.
    static func findCover(artist: String, album: String, fallbackTerm: String) async throws -> Data {
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        var artworkString: String?
        if !cleanAlbum.isEmpty, cleanAlbum.lowercased() != "unknown album" {
            let term = [cleanArtist, cleanAlbum].filter { !$0.isEmpty }.joined(separator: " ")
            let albums = try await search(term: term, entity: "album", limit: 8)
            let want = normalise(cleanAlbum)
            let exact = albums.first { normalise($0.collectionName ?? "") == want && $0.artworkUrl100 != nil }
            let loose = albums.first {
                let got = normalise($0.collectionName ?? "")
                return !got.isEmpty && (got.hasPrefix(want) || want.hasPrefix(got)) && $0.artworkUrl100 != nil
            }
            artworkString = (exact ?? loose)?.artworkUrl100
        }
        if artworkString == nil {
            let songs = try await search(term: fallbackTerm, entity: "song", limit: 5)
            artworkString = songs.first { $0.artworkUrl100 != nil }?.artworkUrl100
        }
        guard let artworkString,
              let url = largeArtworkURL(artworkString) ?? URL(string: artworkString) else {
            throw TagLookupError.noResults
        }
        return try await downloadArtwork(url)
    }

    /// Downloads `url`, or `fallback` when the first fails (404, bad image).
    static func downloadArtwork(_ url: URL, fallback: URL?) async throws -> Data {
        do {
            return try await downloadArtwork(url)
        } catch {
            if error is CancellationError { throw error }
            guard let fallback, fallback != url else { throw error }
            return try await downloadArtwork(fallback)
        }
    }

    /// Downloads a cover image and returns it as JPEG data.
    static func downloadArtwork(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Cover Art Archive answers with a redirect to archive.org; the
        // session follows it. Identify the app the way MusicBrainz asks.
        request.setValue(LookupHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let fetched: (Data, URLResponse)
        do {
            fetched = try await URLSession.shared.data(for: request)
        } catch {
            throw mapped(error)
        }
        let (data, response) = fetched
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TagLookupError.badImage }
        guard let jpeg = await normalizedJPEG(data) else { throw TagLookupError.badImage }
        return jpeg
    }

    // MARK: - Query helpers

    /// "Artist Title" from the editor fields, or a cleaned-up file name stem
    /// ("01_Some_Artist - Song.flac" -> "Some Artist Song") when both are empty.
    static func queryTerm(artist: String, title: String, fileName: String) -> String {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            return [a, t].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let stem = (fileName as NSString).deletingPathExtension
        let parsed = MetadataReader.parseFilename(stem)
        let fileArtist = a.isEmpty ? (parsed.artist ?? "") : a
        return [fileArtist, parsed.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Image normalisation

    /// Decodes any image the system understands (JPEG, PNG, HEIC…) straight
    /// to at most `maxPixel` on its long side and re-encodes it as JPEG, the
    /// format the tag writers embed. Decoding through ImageIO keeps a 48 MP
    /// photo from ever being expanded to full size in memory.
    static func normalizedJPEG(_ data: Data?, maxPixel: CGFloat = 1200) async -> Data? {
        guard let data, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }

    // MARK: - Internals

    private static func search(term: String, entity: String, limit: Int) async throws -> [Response.Item] {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TagLookupError.emptyQuery }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: cleaned),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50))))
        ]
        guard let url = components?.url else { throw TagLookupError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        let fetched: (Data, URLResponse)
        do {
            fetched = try await URLSession.shared.data(for: request)
        } catch {
            throw mapped(error)
        }
        let (data, response) = fetched
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TagLookupError.badResponse
        }
        return decoded.results
    }

    private static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        guard let urlError = error as? URLError else { return TagLookupError.badResponse }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut:
            return TagLookupError.offline
        default:
            return TagLookupError.badResponse
        }
    }

    /// The API hands back a 100px thumbnail; the same path serves 600px.
    private static func largeArtworkURL(_ small: String) -> URL? {
        guard small.contains("100x100bb") else { return nil }
        return URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    private static func year(from releaseDate: String?) -> Int? {
        guard let releaseDate, releaseDate.count >= 4,
              let y = Int(releaseDate.prefix(4)), (1...9999).contains(y) else { return nil }
        return y
    }

    private static func positive(_ n: Int?) -> Int? {
        guard let n, n > 0, n <= 9999 else { return nil }
        return n
    }

    /// Case, accents and punctuation folded away.
    private static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
