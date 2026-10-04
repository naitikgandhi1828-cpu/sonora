//
//  GoogleDriveAuth.swift
//  Sonora
//
//  Google sign-in for the Drive feature.
//
//  This is the standard flow for an installed app that cannot keep a secret:
//  OAuth 2.0 "authorization code" with PKCE (S256), shown in the system's
//  own sign-in sheet (ASWebAuthenticationSession). There is no client secret.
//  Google returns to the app on the custom scheme
//  "com.googleusercontent.apps.<client id>", which the sheet intercepts by
//  itself, so nothing has to be registered in Info.plist.
//
//  The long-lived refresh token is kept in the Keychain. The short-lived
//  access token stays in memory only. Neither is ever printed or logged.
//

import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

// MARK: - Keychain

enum DriveKeychain {

    private static let service = "Sonora.GoogleDrive"
    static let refreshTokenAccount = "refreshToken"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let query = baseQuery(account)
        // Replace rather than update: simpler, and it also resets the
        // accessibility class if an older item had a different one.
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        // Readable after the first unlock following a restart, and never
        // copied to another device through a backup.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

// MARK: - PKCE and form encoding

enum DrivePKCE {

    /// Random bytes as URL-safe base64 without padding.
    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SystemRandomNumberGenerator is also cryptographically secure.
            var generator = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    /// The S256 challenge: base64url(SHA-256(verifier)), no padding.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum DriveForm {

    /// Only the characters RFC 3986 calls "unreserved" are left as they are.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// application/x-www-form-urlencoded body.
    static func body(_ fields: [(String, String)]) -> Data {
        let text = fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        return Data(text.utf8)
    }
}

// MARK: - Small helpers

/// Lets exactly one caller through. Used so a continuation is resumed once
/// even if the system were to report a result twice.
final class DriveOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Tells the sign-in sheet which window to appear over.
final class DriveAuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // CarPlay scenes are not UIWindowScenes, so they drop out here.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        if let scene {
            if let key = scene.keyWindow { return key }
            if let first = scene.windows.first { return first }
            return UIWindow(windowScene: scene)
        }
        return ASPresentationAnchor()
    }
}

/// What Google's token endpoint answers, for both success and failure.
struct DriveTokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Double?
    let refreshToken: String?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case error
        case errorDescription = "error_description"
    }
}

// MARK: - Auth

@MainActor
final class GoogleDriveAuth {

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    /// One refresh at a time; everyone who needs a token waits on the same one.
    private var refreshTask: Task<String, Error>?
    /// Held so the sign-in sheet is not released while it is on screen.
    private var webSession: ASWebAuthenticationSession?
    private let anchorProvider = DriveAuthAnchorProvider()

    /// Whether a saved sign-in exists (it may still turn out to be expired).
    var hasSavedSignIn: Bool {
        DriveKeychain.read(account: DriveKeychain.refreshTokenAccount) != nil
    }

    // MARK: Sign in

    /// Shows Google's sign-in sheet and, on success, stores the refresh token.
    func signIn(clientPrefix prefix: String) async throws {
        let verifier = DrivePKCE.randomURLSafe(byteCount: 32)     // 43 characters
        let state = DrivePKCE.randomURLSafe(byteCount: 16)
        let clientID = GoogleDriveConfig.fullClientID(prefix: prefix)
        let redirect = GoogleDriveConfig.redirectURI(prefix: prefix)

        guard var components = URLComponents(string: GoogleDriveConfig.authEndpoint) else {
            throw DriveError.badResponse
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleDriveConfig.scope),
            URLQueryItem(name: "code_challenge", value: DrivePKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // offline + consent: Google only hands out a refresh token when
            // the consent screen is actually shown.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let authURL = components.url else { throw DriveError.badResponse }

        let callback = try await runWebSession(url: authURL,
                                               scheme: GoogleDriveConfig.callbackScheme(prefix: prefix))

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        if let problem = value("error") {
            if problem == "access_denied" { throw DriveError.cancelled }
            throw DriveError.signInFailed("Google didn't finish the sign-in (\(problem)).")
        }
        // The answer must belong to the request we just made.
        guard let returnedState = value("state"), returnedState == state else {
            throw DriveError.signInFailed("The sign-in answer didn't match the request. Please try again.")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw DriveError.signInFailed("Google didn't send a sign-in code. Please try again.")
        }

        let response: DriveTokenResponse
        do {
            response = try await Self.requestTokens([
                ("client_id", clientID),
                ("code", code),
                ("code_verifier", verifier),
                ("grant_type", "authorization_code"),
                ("redirect_uri", redirect)
            ])
        } catch DriveError.signInExpired {
            // invalid_grant while trading the code: the code itself was refused.
            throw DriveError.signInFailed("Google didn't accept the sign-in code. Please try again.")
        }

        guard let token = response.accessToken, !token.isEmpty else { throw DriveError.badResponse }
        if let granted = response.scope, !granted.contains(GoogleDriveConfig.scope) {
            throw DriveError.signInFailed("Sonora wasn't given permission to see your Drive files. Connect again and leave the Google Drive box ticked.")
        }
        guard let refresh = response.refreshToken, !refresh.isEmpty else {
            throw DriveError.signInFailed("Google didn't send a long-term sign-in. Please try again.")
        }
        guard DriveKeychain.save(refresh, account: DriveKeychain.refreshTokenAccount) else {
            throw DriveError.signInFailed("Couldn't save the sign-in on this iPhone. Please try again.")
        }
        store(accessToken: token, expiresIn: response.expiresIn)
    }

    private func runWebSession(url: URL, scheme: String) async throws -> URL {
        webSession?.cancel()
        webSession = nil
        defer { webSession = nil }

        let provider = anchorProvider
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let once = DriveOnce()
            let handler = Self.completionHandler { result in
                guard once.claim() else { return }
                continuation.resume(with: result)
            }
            let session = ASWebAuthenticationSession(url: url,
                                                     callbackURLScheme: scheme,
                                                     completionHandler: handler)
            session.presentationContextProvider = provider
            // Share Safari's cookies so an existing Google sign-in is reused.
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start(), once.claim() {
                continuation.resume(throwing: DriveError.signInFailed("Couldn't open the Google sign-in page."))
            }
        }
    }

    /// Built outside the main actor on purpose: the system does not promise
    /// which thread it reports the result on, and this closure only forwards it.
    private nonisolated static func completionHandler(
        _ finish: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> (URL?, Error?) -> Void {
        return { callbackURL, error in
            if let callbackURL {
                finish(.success(callbackURL))
            } else if let authError = error as? ASWebAuthenticationSessionError,
                      authError.code == .canceledLogin {
                finish(.failure(DriveError.cancelled))
            } else {
                finish(.failure(DriveError.signInFailed(
                    error?.localizedDescription ?? "Google sign-in didn't finish.")))
            }
        }
    }

    // MARK: Tokens

    /// A token that is good for at least another minute, refreshing if needed.
    func validAccessToken(clientPrefix: String) async throws -> String {
        if let token = accessToken, Date() < accessExpiry { return token }
        return try await refresh(clientPrefix: clientPrefix)
    }

    /// Call after Drive answered 401 for `stale`. Several downloads can hit
    /// that at once; only the first one causes a real refresh.
    func refreshedToken(replacing stale: String, clientPrefix: String) async throws -> String {
        if let token = accessToken, token != stale, Date() < accessExpiry { return token }
        accessToken = nil
        accessExpiry = .distantPast
        return try await refresh(clientPrefix: clientPrefix)
    }

    private func refresh(clientPrefix: String) async throws -> String {
        if let running = refreshTask { return try await running.value }
        guard let refreshToken = DriveKeychain.read(account: DriveKeychain.refreshTokenAccount) else {
            throw DriveError.notConnected
        }
        let clientID = GoogleDriveConfig.fullClientID(prefix: clientPrefix)

        let task = Task<String, Error> { [weak self] in
            let response = try await GoogleDriveAuth.requestTokens([
                ("client_id", clientID),
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken)
            ])
            guard let token = response.accessToken, !token.isEmpty else { throw DriveError.badResponse }
            self?.store(accessToken: token, expiresIn: response.expiresIn)
            // Google may hand back a replacement refresh token.
            if let rotated = response.refreshToken, !rotated.isEmpty, rotated != refreshToken {
                DriveKeychain.save(rotated, account: DriveKeychain.refreshTokenAccount)
            }
            return token
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch DriveError.signInExpired {
            // The saved sign-in is dead; keeping it would only fail again.
            clearTokens()
            throw DriveError.signInExpired
        }
    }

    private func store(accessToken token: String, expiresIn: Double?) {
        accessToken = token
        // Treat it as expired a minute early so a request never starts with
        // a token that runs out on the way.
        let lifetime = max(60, (expiresIn ?? 3600)) - 60
        accessExpiry = Date().addingTimeInterval(lifetime)
    }

    private func clearTokens() {
        accessToken = nil
        accessExpiry = .distantPast
        DriveKeychain.delete(account: DriveKeychain.refreshTokenAccount)
    }

    // MARK: Sign out

    /// Forgets the sign-in on this iPhone and asks Google to cancel it too.
    func signOut() async {
        let saved = DriveKeychain.read(account: DriveKeychain.refreshTokenAccount)
        refreshTask?.cancel()
        refreshTask = nil
        clearTokens()
        guard let saved else { return }
        await Self.revoke(token: saved)
    }

    private nonisolated static func revoke(token: String) async {
        guard var components = URLComponents(string: GoogleDriveConfig.revokeEndpoint) else { return }
        components.percentEncodedQuery = "token=" + DriveForm.encode(token)
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Best effort: if this fails the token still stops working when the
        // user removes Sonora at myaccount.google.com/permissions.
        _ = try? await DriveAPI.session.data(for: request)
    }

    // MARK: Token endpoint

    private nonisolated static func requestTokens(_ fields: [(String, String)]) async throws -> DriveTokenResponse {
        guard let url = URL(string: GoogleDriveConfig.tokenEndpoint) else { throw DriveError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = DriveForm.body(fields)

        let fetched: (Data, URLResponse)
        do {
            fetched = try await DriveAPI.session.data(for: request)
        } catch let error as URLError {
            throw DriveError.fromURLError(error)
        }
        let data = fetched.0
        let response = fetched.1

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(DriveTokenResponse.self, from: data)
        if status == 200, let decoded, decoded.error == nil, decoded.accessToken != nil {
            return decoded
        }

        switch decoded?.error ?? "" {
        case "invalid_grant":
            throw DriveError.signInExpired
        case "invalid_client", "unauthorized_client":
            throw DriveError.signInFailed("Google didn't recognise the Client ID. Check that you pasted an iOS-type OAuth client ID.")
        case "":
            throw DriveError.signInFailed("Google sign-in failed (error \(status)). Please try again.")
        default:
            let detail = decoded?.errorDescription ?? decoded?.error ?? ""
            throw DriveError.signInFailed("Google sign-in failed: \(detail)")
        }
    }
}
