//
//  FolderAccessManager.swift
//  Sonora
//
//  iOS hands out sandboxed access to user-picked folders through
//  security-scoped bookmarks. This resolves them once per launch and keeps
//  the scope open for the life of the process.
//

import Foundation

final class FolderAccessManager {

    static let shared = FolderAccessManager()

    private var resolvedRoots: [UUID: URL] = [:]
    private var openScopes: [UUID: URL] = [:]
    private let lock = NSLock()

    private init() {}

    /// Creates a bookmark for a folder the user just picked.
    func makeBookmark(for url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try url.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        } catch {
            print("[FolderAccess] bookmark failed: \(error)")
            return nil
        }
    }

    /// Resolves and opens a root's security scope. Returns the live URL.
    @discardableResult
    func resolve(_ root: FolderRoot) -> URL? {
        lock.lock()
        if let cached = resolvedRoots[root.id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: root.bookmark,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() {
                lock.lock()
                openScopes[root.id] = url
                resolvedRoots[root.id] = url
                lock.unlock()
            } else {
                lock.lock()
                resolvedRoots[root.id] = url
                lock.unlock()
            }
            if stale { print("[FolderAccess] stale bookmark for \(root.displayName)") }
            return url
        } catch {
            print("[FolderAccess] resolve failed for \(root.displayName): \(error)")
            return nil
        }
    }

    /// Resolves a standalone file bookmark (a track imported on its own).
    func resolveStandalone(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    func release(_ rootID: UUID) {
        lock.lock()
        if let url = openScopes.removeValue(forKey: rootID) {
            url.stopAccessingSecurityScopedResource()
        }
        resolvedRoots.removeValue(forKey: rootID)
        lock.unlock()
    }

    func releaseAll() {
        lock.lock()
        for (_, url) in openScopes { url.stopAccessingSecurityScopedResource() }
        openScopes.removeAll()
        resolvedRoots.removeAll()
        lock.unlock()
    }

    /// The app's own Documents folder, which is exposed to the Files app so
    /// the user can drop music straight in.
    static var documentsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
