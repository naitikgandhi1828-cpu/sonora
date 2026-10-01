//
//  OnlineLookupCore.swift
//  Sonora
//
//  Shared plumbing for the free, key-less online catalogues Sonora can ask
//  for tags, covers and lyrics: iTunes Search, Deezer, MusicBrainz (+ Cover
//  Art Archive) and LRCLIB.
//
//  Ground rules, the same ones ITunesTagLookup and ArtworkFinder follow:
//    • HTTPS only, short timeouts, no retries.
//    • A request carries nothing but the artist / title / album text the
//      user already sees, plus an honest User-Agent naming the app.
//    • Lookups only run on an explicit tap in the tag editor or lyrics
//      sheet, or from ArtworkFinder's existing (user-switchable) flow.
//

import Foundation

// MARK: - Sources

/// A catalogue that can answer song / album searches.
enum LookupSource: String, CaseIterable, Identifiable, Hashable {
    case itunes
    case deezer
    case musicbrainz

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .itunes: return "iTunes"
        case .deezer: return "Deezer"
        case .musicbrainz: return "MusicBrainz"
        }
    }

    /// Short label for the badge on a result row.
    var shortName: String {
        switch self {
        case .itunes: return "iTunes"
        case .deezer: return "Deezer"
        case .musicbrainz: return "MB"
        }
    }

    /// `@AppStorage` key for the per-source switch. All default to on.
    var enabledKey: String { "lookup.source.\(rawValue)" }

    /// Small bias used only to break ties between equally good matches:
    /// iTunes and Deezer have clean, consistent catalogue data and covers.
    var tieBreak: Double {
        switch self {
        case .itunes: return 0.3
        case .deezer: return 0.2
        case .musicbrainz: return 0.1
        }
    }

    /// Whether the user left this source switched on (read straight from
    /// UserDefaults so non-view code such as ArtworkFinder can ask too).
    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    static var enabledSources: [LookupSource] {
        allCases.filter(\.isEnabled)
    }
}

/// Optional structured hints next to the free-text query. When present
/// (and the user didn't retype the query) Deezer and MusicBrainz get a
/// fielded query, which is far more precise than free text.
struct LookupHint: Equatable {
    var artist: String = ""
    var title: String = ""
    var album: String = ""

    var isEmpty: Bool {
        LookupText.clean(artist).isEmpty && LookupText.clean(title).isEmpty && LookupText.clean(album).isEmpty
    }
}

// MARK: - HTTP

enum LookupHTTP {

    /// "Sonora/1.7 ( offline music player )". MusicBrainz and LRCLIB both
    /// ask clients to identify themselves.
    static let userAgent: String = {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.7"
        return "Sonora/\(version) ( offline music player )"
    }()

    /// Its own session so a slow catalogue can't hold up anything else, with
    /// a hard cap on the whole transfer as well as the idle timeout.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 9
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        config.httpAdditionalHeaders = ["User-Agent": LookupHTTP.userAgent]
        return URLSession(configuration: config)
    }()

    /// GET returning the body and status code. Network errors are mapped to
    /// TagLookupError so the UI can show a friendly message.
    static func get(_ url: URL,
                    timeout: TimeInterval = 9,
                    accept: String? = "application/json") async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw mapped(error)
        }
    }

    /// GET + decode; anything but a 200 with valid JSON is `.badResponse`.
    static func json<T: Decodable>(_ type: T.Type, from url: URL, timeout: TimeInterval = 9) async throws -> T {
        let (data, status) = try await get(url, timeout: timeout)
        guard status == 200 else {
            throw status == 404 ? TagLookupError.noResults : TagLookupError.badResponse
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TagLookupError.badResponse
        }
    }

    static func mapped(_ error: Error) -> Error {
        if error is CancellationError || error is TagLookupError { return error }
        guard let urlError = error as? URLError else { return TagLookupError.badResponse }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return TagLookupError.timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed:
            return TagLookupError.offline
        default:
            return TagLookupError.badResponse
        }
    }

    /// Runs `operation`, giving up after `seconds`. Used so that one slow
    /// catalogue can't keep a merged search spinning.
    static func withDeadline<T: Sendable>(_ seconds: Double,
                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: Optional<T>.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw TagLookupError.timedOut
            }
            return value
        }
    }

    static func url(_ base: String, _ items: [(String, String)]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components?.url
    }
}

// MARK: - MusicBrainz rate limit

/// MusicBrainz allows one request per second per client. Every MusicBrainz
/// call reserves the next free slot here before going out, so concurrent
/// searches (or a whole-library artwork sweep) queue up instead of being
/// throttled with 503s.
actor MusicBrainzGate {
    static let shared = MusicBrainzGate()

    private var nextSlot: Date = .distantPast
    private let spacing: TimeInterval = 1.1

    func waitTurn() async throws {
        // The slot is claimed before the first suspension point, so
        // re-entrant callers each get their own, later slot.
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(spacing)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        try Task.checkCancellation()
    }
}

// MARK: - Text matching

enum LookupText {

    static func clean(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case, accents and punctuation folded away so "Sgt. Pepper's" and
    /// "Sgt Peppers" compare equal. Same folding as ArtworkFinder.
    static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(normalise(s).split(separator: " ").map(String.init))
    }

    /// "Album (Deluxe Edition) [Remastered]" -> "Album".
    static func strippingEditionSuffixes(_ s: String) -> String {
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

    /// "Unknown Artist", "Unknown Album" and blanks carry no information.
    static func isPlaceholder(_ s: String) -> Bool {
        let n = normalise(s)
        return n.isEmpty || n == "unknown artist" || n == "unknown album" || n == "various artists"
    }

    /// Escapes a value for a Lucene phrase (MusicBrainz) or Deezer's
    /// `field:"…"` syntax.
    static func quoted(_ s: String) -> String {
        let escaped = clean(s)
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
        return "\"\(escaped)\""
    }

    static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4,
              let y = Int(date.prefix(4)), (1...9999).contains(y) else { return nil }
        return y
    }

    static func positive(_ n: Int?) -> Int? {
        guard let n, n > 0, n <= 9999 else { return nil }
        return n
    }
}
