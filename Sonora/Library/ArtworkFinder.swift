//
//  ArtworkFinder.swift
//  Sonora
//
//  Fills in album art the scan could not find.
//
//  Three sources, cheapest first:
//
//    1. A cover image sitting beside the audio files. The indexer already looks
//       for one, but folders change after a scan — art dropped in later, or a
//       root re-mounted read-only at scan time — so it is worth another look.
//    2. Artwork embedded in a *sibling* track. Cue rips and multi-disc sets
//       often tag only one file of the album.
//    3. The iTunes Search API, which needs no key and returns 600px covers.
//
//  Only the third leaves the device, and only when the user has left "Download
//  missing artwork" on. Everything found is written into the shared
//  ArtworkStore under the album key, so one lookup covers a whole album.
//

import Foundation
import UIKit

@MainActor
final class ArtworkFinder: ObservableObject {

    /// Progress for the Settings screen's "Find Missing Artwork" button.
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status: String = ""
    @Published private(set) var lastFoundCount = 0

    /// Fired with the album key each time a cover is found, so whatever is on
    /// screen (and the Now Playing lock-screen entry) can pick it up without
    /// polling the library.
    var onArtworkFound: ((String) -> Void)?

    private let settings: AppSettings
    private unowned let library: MediaLibrary

    /// Album keys already tried this launch, successfully or not, so a track
    /// starting inside an album with genuinely no art does not fire a request
    /// every time it plays.
    private var attempted: Set<String> = []
    private var cancelled = false

    init(settings: AppSettings, library: MediaLibrary) {
        self.settings = settings
        self.library = library
    }

    // MARK: - On-demand, for the track that just started

    /// Looks for art for one track in the background. Cheap and idempotent:
    /// it returns immediately when the album already has a cover, when the
    /// album has been tried before, or when a sweep is already running.
    func findIfMissing(for track: Track) {
        guard !isRunning, track.artworkKey == nil else { return }
        let key = track.albumKey
        guard !attempted.contains(key) else { return }
        attempted.insert(key)

        Task { [weak self] in
            guard let self else { return }
            if await self.find(for: track, allowNetwork: self.settings.downloadMissingArtwork) {
                self.lastFoundCount += 1
            }
        }
    }

    // MARK: - Whole-library sweep

    func cancel() { cancelled = true }

    /// Walks every album that has no cover and tries to find one.
    func findMissingArtwork() async {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        progress = 0
        lastFoundCount = 0

        // One representative track per album without art. Albums are the unit
        // of work because artwork is stored per album key.
        var byAlbum: [String: Track] = [:]
        for track in library.tracks where track.artworkKey == nil {
            if byAlbum[track.albumKey] == nil { byAlbum[track.albumKey] = track }
        }
        let jobs = Array(byAlbum.values)

        guard !jobs.isEmpty else {
            status = "Every album already has artwork."
            isRunning = false
            return
        }

        let allowNetwork = settings.downloadMissingArtwork
        var found = 0
        for (i, track) in jobs.enumerated() {
            if cancelled { break }
            status = "\(track.displayAlbum) — \(i + 1) of \(jobs.count)"
            progress = Double(i) / Double(jobs.count)
            if await find(for: track, allowNetwork: allowNetwork) { found += 1 }
        }

        progress = 1
        lastFoundCount = found
        status = cancelled
            ? "Stopped after \(found) of \(jobs.count)."
            : "Found artwork for \(found) of \(jobs.count) album\(jobs.count == 1 ? "" : "s")."
        isRunning = false
    }

    // MARK: - One album

    @discardableResult
    private func find(for track: Track, allowNetwork: Bool) async -> Bool {
        let albumKey = track.albumKey

        // Somebody may have filled this album in already.
        if let existing = ArtworkStore.shared.hasArtwork(forAlbumKey: albumKey) {
            adopt(key: existing, forAlbumKey: albumKey)
            return true
        }

        if let key = await localArtwork(for: track, albumKey: albumKey) {
            adopt(key: key, forAlbumKey: albumKey)
            return true
        }

        guard allowNetwork else { return false }

        guard let data = await Self.downloadCover(artist: track.effectiveAlbumArtist,
                                                  album: track.displayAlbum),
              let key = await Self.store(data, forAlbumKey: albumKey) else { return false }
        adopt(key: key, forAlbumKey: albumKey)
        return true
    }

    /// Sidecar image beside the files, or art embedded in a sibling track.
    private func localArtwork(for track: Track, albumKey: String) async -> String? {
        guard let url = library.url(for: track) else { return nil }
        let folder = url.deletingLastPathComponent()

        if let key = await Task.detached(priority: .utility, operation: {
            ArtworkStore.shared.importSidecarArtwork(in: folder, albumKey: albumKey)
        }).value {
            return key
        }

        // Siblings: read tags off the other files of the same album until one
        // yields a picture. Capped so a 40-track box set cannot stall a sweep.
        let siblings = library.tracks
            .filter { $0.albumKey == albumKey && $0.id != track.id }
            .prefix(8)
            .compactMap { library.url(for: $0) }

        for candidate in [url] + siblings {
            if let data = await MetadataReader.artworkData(at: candidate),
               let key = await Self.store(data, forAlbumKey: albumKey) {
                return key
            }
        }
        return nil
    }

    /// Decode, resize and write, off the main thread.
    nonisolated private static func store(_ data: Data, forAlbumKey albumKey: String) async -> String? {
        await Task.detached(priority: .utility) {
            ArtworkStore.shared.store(data, forAlbumKey: albumKey)
        }.value
    }

    /// Points every track of the album at the artwork we just stored.
    private func adopt(key: String, forAlbumKey albumKey: String) {
        library.setArtworkKey(key, forAlbumKey: albumKey)
        onArtworkFound?(albumKey)
    }

    // MARK: - iTunes Search

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    /// Queries the iTunes Search API and returns the best cover's bytes.
    ///
    /// No key, no account, HTTPS only, and the request carries nothing but the
    /// artist and album names already in the user's tags.
    nonisolated private static func downloadCover(artist: String, album: String) async -> Data? {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = Self.strippingEditionSuffixes(album)
        guard !album.isEmpty, album.lowercased() != "unknown album" else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)".trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }

        guard let best = bestMatch(in: decoded.results, artist: artist, album: album),
              let artworkURL = best.artworkUrl100 else { return nil }

        // The API hands back a 100px thumbnail; the same path serves any size.
        let large = artworkURL.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        guard let imageURL = URL(string: large),
              let (imageData, imageResponse) = try? await URLSession.shared.data(from: imageURL),
              (imageResponse as? HTTPURLResponse)?.statusCode == 200,
              UIImage(data: imageData) != nil else { return nil }
        return imageData
    }

    /// Picks the result whose album title actually matches, so a search that
    /// finds only loosely related records returns nothing rather than the
    /// wrong cover. A wrong cover is worse than no cover: it is silent, it
    /// looks deliberate, and the user has no reason to suspect it.
    nonisolated private static func bestMatch(in results: [SearchResponse.Result],
                                  artist: String,
                                  album: String) -> SearchResponse.Result? {
        let wantAlbum = normalise(album)
        let wantArtist = normalise(artist)
        guard !wantAlbum.isEmpty else { return nil }

        var best: (result: SearchResponse.Result, score: Int)?
        for result in results {
            let gotAlbum = normalise(strippingEditionSuffixes(result.collectionName ?? ""))
            guard !gotAlbum.isEmpty else { continue }

            var score = 0
            if gotAlbum == wantAlbum {
                score += 4
            } else if gotAlbum.hasPrefix(wantAlbum) || wantAlbum.hasPrefix(gotAlbum) {
                score += 2
            } else {
                continue    // album title has to match; artist alone is not enough
            }

            let gotArtist = normalise(result.artistName ?? "")
            if !wantArtist.isEmpty, gotArtist == wantArtist {
                score += 3
            } else if !wantArtist.isEmpty,
                      gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist) {
                score += 1
            }

            if score > (best?.score ?? 0) { best = (result, score) }
        }
        return best?.result
    }

    /// "Album (Deluxe Edition) [Remastered]" -> "Album".
    nonisolated private static func strippingEditionSuffixes(_ s: String) -> String {
        var out = s
        for pattern in ["\\s*\\([^)]*\\)\\s*$", "\\s*\\[[^\\]]*\\]\\s*$"] {
            while let range = out.range(of: pattern, options: .regularExpression) {
                let trimmed = String(out[out.startIndex..<range.lowerBound])
                if trimmed.trimmingCharacters(in: .whitespaces).isEmpty { break }
                out = trimmed
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case, accents and punctuation folded away so "Sgt. Pepper's" and
    /// "Sgt Peppers" compare equal.
    nonisolated private static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
