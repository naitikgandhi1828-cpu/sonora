//
//  GoogleDriveAPI.swift
//  Sonora
//
//  The handful of Google Drive v3 calls Sonora needs: who is signed in,
//  what is inside a folder, and downloading one file. Plain URLSession with
//  async/await; no Google SDK.
//
//  Every function takes the access token as a parameter and throws
//  `DriveError.unauthorized` on HTTP 401, so the caller (GoogleDriveManager)
//  can refresh the token once and try again.
//

import Foundation
import Network

enum DriveAPI {

    /// One session for everything Drive. No URL cache: listings must be
    /// fresh, and music files must never be copied into a cache as well.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 2
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["User-Agent": LookupHTTP.userAgent]
        return URLSession(configuration: config)
    }()

    /// Where a download lands before it is moved into the library folder.
    static var stagingFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SonoraDrive", isDirectory: true)
    }

    // MARK: Account

    private struct About: Decodable {
        struct User: Decodable {
            let emailAddress: String?
            let displayName: String?
        }
        let user: User?
    }

    /// The signed-in person's email and name.
    static func account(token: String) async throws -> (email: String?, name: String?) {
        guard var components = URLComponents(string: GoogleDriveConfig.apiBase + "/about") else {
            throw DriveError.badResponse
        }
        components.queryItems = [URLQueryItem(name: "fields", value: "user(emailAddress,displayName)")]
        guard let url = components.url else { throw DriveError.badResponse }
        let about = try await getJSON(About.self, url: url, token: token)
        return (about.user?.emailAddress, about.user?.displayName)
    }

    // MARK: Listing

    /// Drive sends `size` as text ("1234567"); accept a number as well.
    private struct FlexibleInt: Decodable {
        let value: Int64?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                value = Int64(text)
            } else if let number = try? container.decode(Int64.self) {
                value = number
            } else {
                value = nil
            }
        }
    }

    private struct Shortcut: Decodable {
        let targetId: String?
        let targetMimeType: String?
    }

    private struct File: Decodable {
        let id: String?
        let name: String?
        let mimeType: String?
        let size: FlexibleInt?
        let modifiedTime: String?
        let md5Checksum: String?
        let shortcutDetails: Shortcut?
    }

    private struct FileList: Decodable {
        let nextPageToken: String?
        let files: [File]?
    }

    /// Folders and playable audio files directly inside `folder`, folders
    /// first, each group sorted by name. Follows every page of results.
    static func list(folder: DriveFolderRef, token: String) async throws -> [DriveItem] {
        let query: String
        switch folder.kind {
        case .sharedWithMe:
            query = "sharedWithMe and trashed=false"
        case .folder:
            // Inside the query, a quote or backslash in the id must be escaped.
            let safeID = folder.id
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            query = "'\(safeID)' in parents and trashed=false"
        }

        var result: [DriveItem] = []
        var seen = Set<String>()
        var pageToken: String?
        var pages = 0

        repeat {
            try Task.checkCancellation()
            guard var components = URLComponents(string: GoogleDriveConfig.apiBase + "/files") else {
                throw DriveError.badResponse
            }
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields",
                             value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,md5Checksum,shortcutDetails)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "orderBy", value: "folder,name"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = items
            // URLComponents leaves "+" alone, but servers read it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else { throw DriveError.badResponse }

            let page = try await getJSON(FileList.self, url: url, token: token)
            for file in page.files ?? [] {
                guard let item = makeItem(from: file), seen.insert(item.id).inserted else { continue }
                result.append(item)
            }
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < 200

        return result.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Keeps folders and playable audio; follows shortcuts to their target.
    private static func makeItem(from file: File) -> DriveItem? {
        guard var id = file.id, let name = file.name, var mime = file.mimeType,
              !id.isEmpty, !name.isEmpty else { return nil }

        var isShortcut = false
        if mime == GoogleDriveConfig.shortcutMimeType {
            guard let target = file.shortcutDetails?.targetId, !target.isEmpty,
                  let targetMime = file.shortcutDetails?.targetMimeType else { return nil }
            id = target
            mime = targetMime
            isShortcut = true
        }

        if mime == GoogleDriveConfig.folderMimeType {
            return DriveItem(id: id, name: name, isFolder: true,
                             size: nil, modifiedTime: nil, md5: nil, localName: name)
        }
        // Google Docs, Sheets and so on are not files that can be downloaded.
        if mime.hasPrefix("application/vnd.google-apps") { return nil }
        guard let localName = DriveFileNames.playableLocalName(name: name, mimeType: mime) else {
            return nil
        }
        // A shortcut's own size and dates describe the link, not the song.
        return DriveItem(id: id, name: name, isFolder: false,
                         size: isShortcut ? nil : file.size?.value,
                         modifiedTime: isShortcut ? nil : file.modifiedTime,
                         md5: isShortcut ? nil : file.md5Checksum,
                         localName: localName)
    }

    // MARK: Bin

    /// Moves one file to the Bin in Google Drive. Google keeps it there for
    /// 30 days, so this can be undone from Drive itself. A file that is
    /// already gone counts as done.
    ///
    /// Needs the full Drive permission (`GoogleDriveConfig.fullScope`).
    static func moveToBin(fileID: String, token: String) async throws {
        let safeID = fileID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileID
        guard var components = URLComponents(string: GoogleDriveConfig.apiBase + "/files/" + safeID) else {
            throw DriveError.badResponse
        }
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: "id,trashed")
        ]
        guard let url = components.url else { throw DriveError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"trashed":true}"#.utf8)

        let fetched: (Data, URLResponse)
        do {
            fetched = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw DriveError.fromURLError(error)
        }
        guard let http = fetched.1 as? HTTPURLResponse else { throw DriveError.badResponse }
        if (200..<300).contains(http.statusCode) || http.statusCode == 404 { return }
        if http.statusCode == 401 { throw DriveError.unauthorized }

        // The general messages talk about downloading; these are the two
        // ways a delete is refused.
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: fetched.0)
        let reason = envelope?.error?.errors?.first?.reason ?? ""
        let message = (envelope?.error?.message ?? "").lowercased()
        if reason == "insufficientFilePermissions" || reason == "appNotAuthorizedToFile"
            || message.contains("sufficient permissions for this file") {
            throw DriveError.api("This song belongs to someone else in Google Drive, so only they can delete it.")
        }
        if reason == "insufficientPermissions" || message.contains("insufficient authentication scopes") {
            throw DriveError.api("Sonora isn't allowed to delete from Google Drive yet. Switch on “Allow deleting from Drive” on the Google Drive screen.")
        }
        throw apiError(status: http.statusCode, body: fetched.0)
    }

    // MARK: Download

    /// Downloads one file to `destination`, replacing whatever is there.
    /// Returns the size on disk. `progress` gets the bytes received so far,
    /// a few times a second, on a background thread.
    static func download(fileID: String,
                         token: String,
                         destination: URL,
                         wifiOnly: Bool,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        guard var components = URLComponents(
            string: GoogleDriveConfig.apiBase + "/files/" + DriveForm.encode(fileID)) else {
            throw DriveError.badResponse
        }
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components.url else { throw DriveError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if wifiOnly {
            request.allowsCellularAccess = false
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }

        let fm = FileManager.default
        let staging = stagingFolder.appendingPathComponent(UUID().uuidString + ".part")
        defer { try? fm.removeItem(at: staging) }

        let response: HTTPURLResponse
        do {
            response = try await runDownload(request, staging: staging, progress: progress)
        } catch let error as URLError {
            // Other network errors are passed on untouched: the caller
            // decides from the code whether a retry is worth it.
            if error.code == .cancelled { throw CancellationError() }
            throw error
        }

        guard (200..<300).contains(response.statusCode) else {
            // On an error the "file" is Google's JSON explanation.
            throw apiError(status: response.statusCode, body: smallFile(staging))
        }
        try Task.checkCancellation()

        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)

        let attributes = try? fm.attributesOfItem(atPath: destination.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// At most the first 64 KB of a file (error bodies are tiny).
    private static func smallFile(_ url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 64 * 1024)) ?? Data()
    }

    /// Bookkeeping for one running download: lets it be cancelled from
    /// outside and keeps the progress reports to a few per second.
    private final class DownloadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var observation: NSKeyValueObservation?
        private var cancelled = false
        private var lastReport = Date.distantPast

        func attach(_ task: URLSessionDownloadTask, _ observation: NSKeyValueObservation) {
            lock.lock()
            self.task = task
            self.observation = observation
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = task
            lock.unlock()
            running?.cancel()
        }

        func finish() {
            lock.lock()
            let old = observation
            observation = nil
            task = nil
            lock.unlock()
            old?.invalidate()
        }

        func shouldReport() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            guard now.timeIntervalSince(lastReport) >= 0.3 else { return false }
            lastReport = now
            return true
        }
    }

    /// A classic download task wrapped for async/await. (The async
    /// `download(for:)` call gives no byte progress, so this uses the
    /// completion-handler form and watches the task's byte counter.)
    private static func runDownload(_ request: URLRequest,
                                    staging: URL,
                                    progress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        let box = DownloadBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let task = session.downloadTask(with: request) { tempURL, response, error in
                    box.finish()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let tempURL, let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: DriveError.badResponse)
                        return
                    }
                    // The system deletes its temp file as soon as this
                    // closure returns, so move it right now.
                    do {
                        let fm = FileManager.default
                        try fm.createDirectory(at: staging.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
                        try? fm.removeItem(at: staging)
                        try fm.moveItem(at: tempURL, to: staging)
                        continuation.resume(returning: http)
                    } catch let moveError {
                        continuation.resume(throwing: moveError)
                    }
                }
                let observation = task.observe(\.countOfBytesReceived, options: [.new]) { observed, _ in
                    if box.shouldReport() { progress(observed.countOfBytesReceived) }
                }
                box.attach(task, observation)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: Plumbing

    private static func getJSON<T: Decodable>(_ type: T.Type, url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let fetched: (Data, URLResponse)
        do {
            fetched = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw DriveError.fromURLError(error)
        }
        guard let http = fetched.1 as? HTTPURLResponse else { throw DriveError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw apiError(status: http.statusCode, body: fetched.0)
        }
        do {
            return try JSONDecoder().decode(T.self, from: fetched.0)
        } catch {
            throw DriveError.badResponse
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let reason: String?
            let message: String?
        }
        struct Body: Decodable {
            let message: String?
            let errors: [Detail]?
        }
        let error: Body?
    }

    /// Turns a Drive error answer into something a person can act on.
    static func apiError(status: Int, body: Data) -> DriveError {
        if status == 401 { return .unauthorized }

        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        let reason = envelope?.error?.errors?.first?.reason ?? ""
        let message = envelope?.error?.message ?? ""

        switch reason {
        case "cannotDownloadAbusiveFile":
            return .api("Google flagged this file as unsafe and won't let apps download it.")
        case "downloadQuotaExceeded":
            return .api("This file has been downloaded too many times lately. Google will allow it again later.")
        case "userRateLimitExceeded", "rateLimitExceeded", "dailyLimitExceeded",
             "sharingRateLimitExceeded", "quotaExceeded":
            return .api("Google Drive's download limit was reached. Wait a little, then try again.")
        case "accessNotConfigured":
            return .api("The Google Drive API isn't switched on for your Google Cloud project. Enable “Google Drive API” in the Cloud Console, wait a minute, then try again.")
        case "insufficientPermissions", "insufficientFilePermissions", "appNotAuthorizedToFile":
            return .api("Sonora wasn't given permission for this. Disconnect, then connect again and leave the Google Drive box ticked.")
        case "cannotDownloadFile", "fileNotDownloadable":
            return .api("Google Drive doesn't allow this file to be downloaded.")
        default:
            break
        }

        if status == 404 { return .api("This file is no longer in Google Drive.") }
        if status == 403, message.contains("has not been used in project") || message.contains("is disabled") {
            return .api("The Google Drive API isn't switched on for your Google Cloud project. Enable “Google Drive API” in the Cloud Console, wait a minute, then try again.")
        }
        if status == 429 || status >= 500 {
            return .api("Google Drive is busy right now. Try again in a moment.")
        }
        if !message.isEmpty { return .api("Google Drive: \(message)") }
        return .api("Google Drive answered with error \(status).")
    }
}

// MARK: - Network type

enum DriveNetwork {

    /// One quick look at the current connection: true only on ordinary
    /// Wi-Fi (not a personal hotspot, not Low Data Mode). Nothing keeps
    /// watching afterwards.
    static func isOnWiFi() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let once = DriveOnce()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                let good = path.status == .satisfied
                    && path.usesInterfaceType(.wifi)
                    && !path.isExpensive
                    && !path.isConstrained
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: good)
            }
            monitor.start(queue: DispatchQueue(label: "sonora.drive.network"))
        }
    }
}
