//
//  GoogleDriveModels.swift
//  Sonora
//
//  Shared types for the Google Drive feature: the settings it needs, what a
//  Drive file looks like to the rest of the app, and the errors it can show.
//
//  How the feature works, in one paragraph: the user signs in to Google,
//  browses their Drive, and picks songs or folders. Sonora downloads those
//  files into "Google Drive" inside its own Documents folder, and that folder
//  is a normal library folder, so the songs play offline with every effect.
//  Nothing is streamed and nothing runs in the background.
//

import Foundation

// MARK: - Settings and fixed values

enum GoogleDriveConfig {

    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
    static let apiBase = "https://www.googleapis.com/drive/v3"

    /// Read-only: Sonora can list and download, never change or delete.
    /// This is what Sonora asks for unless the user switches on
    /// "Allow deleting from Drive".
    static let scope = "https://www.googleapis.com/auth/drive.readonly"

    /// Full access, asked for only when the user wants "Delete Song" to
    /// reach Google Drive as well. Sonora uses it for one thing: moving a
    /// song to the Drive Bin.
    static let fullScope = "https://www.googleapis.com/auth/drive"

    static let clientIDSuffix = ".apps.googleusercontent.com"
    static let reversedPrefix = "com.googleusercontent.apps."

    /// Folder inside Documents that holds everything downloaded from Drive.
    static let localFolderName = "Google Drive"

    static let folderMimeType = "application/vnd.google-apps.folder"
    static let shortcutMimeType = "application/vnd.google-apps.shortcut"

    /// How many files download at the same time.
    static let maxConcurrentDownloads = 3

    // UserDefaults keys. The refresh token is NOT here; it lives in the Keychain.
    enum Keys {
        static let clientID = "drive.clientID"
        static let accountEmail = "drive.accountEmail"
        static let accountName = "drive.accountName"
        static let syncOnLaunch = "drive.syncOnLaunch"
        static let needsReconnect = "drive.needsReconnect"
        static let deleteAllowed = "drive.deleteAllowed"
    }

    /// Accepts what the user pasted and returns just the part before
    /// ".apps.googleusercontent.com", or nil when it cannot be a client ID.
    ///
    /// All of these give "1234-abc":
    ///   1234-abc.apps.googleusercontent.com
    ///   1234-abc
    ///   com.googleusercontent.apps.1234-abc        (the "iOS URL scheme" form)
    static func normalisedClientPrefix(_ raw: String) -> String? {
        var text = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
        let lower = text.lowercased()
        if lower.hasPrefix(reversedPrefix) {
            text = String(text.dropFirst(reversedPrefix.count))
            // The scheme form is sometimes copied with ":/oauth2redirect" on the end.
            if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        } else if lower.hasSuffix(clientIDSuffix) {
            text = String(text.dropLast(clientIDSuffix.count))
        }
        guard !text.isEmpty, text.count <= 200 else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }

    static func fullClientID(prefix: String) -> String { prefix + clientIDSuffix }

    /// The custom URL scheme Google sends the sign-in result back on.
    static func callbackScheme(prefix: String) -> String { reversedPrefix + prefix }

    static func redirectURI(prefix: String) -> String {
        callbackScheme(prefix: prefix) + ":/oauth2redirect"
    }
}

// MARK: - Drive items

/// A folder or a playable audio file in Drive. Shortcuts are already
/// followed: `id` is always the real file or folder.
struct DriveItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isFolder: Bool
    /// Bytes. Unknown (nil) for shortcuts, where Drive only describes the link.
    let size: Int64?
    let modifiedTime: String?
    let md5: String?
    /// File name to use on disk: `name`, plus an extension when the Drive
    /// name had none but its type told us what it is.
    let localName: String
}

/// A place in Drive the browser can show.
struct DriveFolderRef: Hashable {
    enum Kind: String, Codable, Hashable {
        /// A real folder (including "My Drive" itself, whose id is "root").
        case folder
        /// The "Shared with me" list, which is a search rather than a folder.
        case sharedWithMe
    }

    var kind: Kind
    var id: String
    var name: String
    /// Folder names from the top of the browser down to this one, used both
    /// for the title line and for where downloads land on disk. Empty for
    /// "My Drive" itself.
    var pathComponents: [String]

    static let myDrive = DriveFolderRef(kind: .folder, id: "root", name: "My Drive", pathComponents: [])
    static let sharedWithMe = DriveFolderRef(kind: .sharedWithMe, id: "sharedWithMe",
                                             name: "Shared with me",
                                             pathComponents: ["Shared with me"])

    func child(_ item: DriveItem) -> DriveFolderRef {
        DriveFolderRef(kind: .folder, id: item.id, name: item.name,
                       pathComponents: pathComponents + [item.name])
    }

    /// "My Drive › Music › Albums"
    var displayPath: String {
        if kind == .sharedWithMe { return name }
        let isUnderShared = pathComponents.first == DriveFolderRef.sharedWithMe.name
        let parts = isUnderShared ? pathComponents : ["My Drive"] + pathComponents
        return parts.joined(separator: " › ")
    }
}

/// A Drive folder the user asked to keep in step with.
struct DriveSyncedFolder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var pathComponents: [String]
    var displayPath: String
    var lastSynced: Date?

    var folderRef: DriveFolderRef {
        DriveFolderRef(kind: .folder, id: id, name: name, pathComponents: pathComponents)
    }
}

/// One file that could not be downloaded, with a reason fit to show.
struct DriveFailure: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let message: String
}

// MARK: - Errors

enum DriveError: LocalizedError, Equatable {
    case notSetUp
    case notConnected
    /// The user closed the Google sign-in sheet.
    case cancelled
    /// Google no longer accepts the saved sign-in (`invalid_grant`).
    case signInExpired
    /// The access token was rejected (HTTP 401); refresh and try again.
    case unauthorized
    case signInFailed(String)
    case network(String)
    /// Drive answered, but with an error. The text is ready to show.
    case api(String)
    case notEnoughSpace(needed: Int64, free: Int64)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notSetUp:
            return "Paste your Google OAuth Client ID first."
        case .notConnected:
            return "Connect Google Drive first."
        case .cancelled:
            return "Sign-in was cancelled."
        case .signInExpired:
            return "Google sign-in expired — connect again."
        case .unauthorized:
            return "Google didn't accept the sign-in. Try connecting again."
        case .signInFailed(let message):
            return message
        case .network(let message):
            return message
        case .api(let message):
            return message
        case .notEnoughSpace(let needed, let free):
            let f = ByteCountFormatter()
            f.countStyle = .file
            return "Not enough free space: these songs need \(f.string(fromByteCount: needed)) and this iPhone has \(f.string(fromByteCount: free)) free."
        case .badResponse:
            return "Google Drive sent an answer Sonora couldn't read. Try again."
        }
    }

    /// Turns anything thrown by the Drive code into a short sentence.
    static func message(for error: Error) -> String {
        if let drive = error as? DriveError { return drive.errorDescription ?? "Something went wrong." }
        if let url = error as? URLError { return fromURLError(url).errorDescription ?? "Network problem." }
        if error is CancellationError { return "Cancelled." }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "This iPhone is out of free space."
        }
        return error.localizedDescription
    }

    static func fromURLError(_ error: URLError) -> DriveError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .network("No internet connection.")
        case .timedOut:
            return .network("Google Drive took too long to answer.")
        case .networkConnectionLost:
            return .network("The connection dropped. Try again.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("Couldn't reach Google. Check your connection.")
        default:
            return .network(error.localizedDescription)
        }
    }

    /// True for a cancelled task or a cancelled network request.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if let drive = error as? DriveError, drive == .cancelled { return true }
        return false
    }
}

// MARK: - File names

enum DriveFileNames {

    /// Extensions for audio that was uploaded without one, by Drive mime type.
    private static let mimeExtensions: [String: String] = [
        "audio/mpeg": "mp3", "audio/mp3": "mp3",
        "audio/flac": "flac", "audio/x-flac": "flac",
        "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/m4a": "m4a",
        "audio/aac": "aac",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav",
        "audio/aiff": "aiff", "audio/x-aiff": "aiff"
    ]

    /// The on-disk name for a Drive file if Sonora can play it, else nil.
    ///
    /// The extension decides (that is what the player goes by). A file with
    /// no extension is accepted only when Drive says it is a common audio
    /// type. Videos named ".mp4" are left out so "download this folder"
    /// never pulls gigabytes of film.
    static func playableLocalName(name: String, mimeType: String) -> String? {
        let mime = mimeType.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, AudioFormats.isPlayable(ext) {
            if mime.hasPrefix("video/"), ext == "mp4" { return nil }
            return name
        }
        if ext.isEmpty, let guessed = mimeExtensions[mime], AudioFormats.isPlayable(guessed) {
            return name + "." + guessed
        }
        return nil
    }

    /// Makes one Drive name safe as a single file or folder name: no "/" or
    /// ":" (path separators), no control characters, not hidden, not empty,
    /// and short enough for the file system.
    static func sanitised(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                out.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                out.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        // A leading dot would hide it from the library scan.
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.isEmpty { return "Untitled" }

        // File names are limited to 255 bytes; leave room for " (12)".
        let limit = 200
        if out.utf8.count > limit {
            let ext = (out as NSString).pathExtension
            var base = (out as NSString).deletingPathExtension
            let suffix = ext.isEmpty || ext.utf8.count > 10 ? "" : "." + ext
            while !base.isEmpty, base.utf8.count + suffix.utf8.count > limit { base.removeLast() }
            base = base.trimmingCharacters(in: .whitespaces)
            out = (base.isEmpty ? "Untitled" : base) + suffix
        }
        return out
    }

    /// "Song.mp3" → "Song (2).mp3"
    static func numbered(_ fileName: String, _ number: Int) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
    }

    /// Joins already-sanitised parts into a relative path.
    static func relativePath(folders: [String], fileName: String) -> String {
        (folders + [fileName]).joined(separator: "/")
    }
}
