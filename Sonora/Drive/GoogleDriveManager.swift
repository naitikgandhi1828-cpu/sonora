//
//  GoogleDriveManager.swift
//  Sonora
//
//  The one object the Drive screens talk to. It owns the sign-in state, the
//  folder listings, the download queue with its progress, the list of synced
//  folders and the record of what has been downloaded.
//
//  Everything here runs on the main actor; the slow parts (network, disk)
//  are awaited and happen elsewhere. Nothing runs unless the user asks for
//  it — the only automatic work is the optional "sync when Sonora opens",
//  which is off by default and Wi-Fi only.
//

import Foundation
import SwiftUI
import UIKit

/// What the browser shows next to a song.
enum DriveItemState: Equatable {
    case notDownloaded
    case queued
    /// Fraction 0...1, or nil when Drive did not say how big the file is.
    case downloading(Double?)
    case downloaded
}

@MainActor
final class GoogleDriveManager: ObservableObject {

    static let shared = GoogleDriveManager()

    enum AuthState: Equatable {
        /// No Client ID has been pasted yet.
        case notSetUp
        case signedOut
        case connecting
        case connected
        /// Google stopped accepting the saved sign-in.
        case expired
    }

    enum Activity: Equatable {
        case idle
        /// Walking Drive folders to see what is in them.
        case looking
        case downloading
        /// Reading tags and adding the new songs to the library.
        case finishing
    }

    // MARK: Published state

    @Published private(set) var authState: AuthState
    @Published private(set) var clientPrefix: String?
    @Published private(set) var accountEmail: String?
    @Published private(set) var accountName: String?
    /// The last sign-in problem, in plain words. Cleared on the next try.
    @Published var authMessage: String?

    /// Drive file id → downloaded file.
    @Published private(set) var downloaded: [String: DriveIndexEntry]
    @Published private(set) var syncedFolders: [DriveSyncedFolder]
    @Published private(set) var syncOnLaunch: Bool
    @Published private(set) var storageBytes: Int64 = 0
    /// Whether "Delete Song" may move songs to the Bin in Google Drive.
    /// Off unless the user switched it on and gave Google's permission.
    @Published private(set) var canDeleteFromDrive: Bool
    /// True while Google's sheet for the delete permission is on screen.
    @Published private(set) var isChangingPermission = false

    @Published private(set) var activity: Activity = .idle
    /// Songs found so far while looking through folders.
    @Published private(set) var foundSoFar = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var finishedCount = 0
    /// Files downloading right now → bytes received so far.
    @Published private(set) var activeBytes: [String: Int64] = [:]
    @Published private(set) var queuedIDs: Set<String> = []
    @Published private(set) var failures: [DriveFailure] = []
    /// One line saying how the last download or sync went.
    @Published var notice: String?

    // MARK: Private state

    private let auth: GoogleDriveAuth
    private var listingCache: [String: [DriveItem]] = [:]
    /// Songs deleted from the iPhone but left in Drive; sync skips them.
    private var ignoredIDs: Set<String>

    private var queue: [DriveJob] = []
    private var activeJobs: [String: DriveJob] = [:]
    private var runner: Task<Void, Never>?
    private var lookTasks: [UUID: Task<Void, Never>] = [:]
    private var isFinishing = false
    private var cancelRequested = false

    private var bytesPlanned: Int64 = 0
    private var bytesFinished: Int64 = 0
    private var sessionAdded = 0
    private var sessionAlready = 0
    /// Downloaded (or found on disk) but not yet added to the library.
    private var pendingPaths: [String] = []
    private var unsavedChanges = 0
    /// Network failures in a row. A few of them mean the connection is
    /// gone, and trying every remaining file would only waste battery.
    private var networkFailuresInARow = 0
    /// True for the automatic sync at launch, which stays silent when
    /// there was nothing to do.
    private var quietSession = false
    private var didCheckAccount = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: Init

    private init() {
        let defaults = UserDefaults.standard
        let prefix = defaults.string(forKey: GoogleDriveConfig.Keys.clientID)
            .flatMap { GoogleDriveConfig.normalisedClientPrefix($0) }
        let snapshot = DriveIndexStore.load()

        let state: AuthState
        if prefix == nil {
            state = .notSetUp
        } else if DriveKeychain.read(account: DriveKeychain.refreshTokenAccount) != nil {
            state = .connected
        } else if defaults.bool(forKey: GoogleDriveConfig.Keys.needsReconnect) {
            state = .expired
        } else {
            state = .signedOut
        }

        // Properties without a default value first; the optional ones (which
        // start as nil) are filled in once the object is fully set up.
        auth = GoogleDriveAuth()
        authState = state
        downloaded = snapshot.files
        syncedFolders = snapshot.syncedFolders
        syncOnLaunch = defaults.bool(forKey: GoogleDriveConfig.Keys.syncOnLaunch)
        canDeleteFromDrive = defaults.bool(forKey: GoogleDriveConfig.Keys.deleteAllowed)
        ignoredIDs = Set(snapshot.ignored ?? [])

        clientPrefix = prefix
        accountEmail = defaults.string(forKey: GoogleDriveConfig.Keys.accountEmail)
        accountName = defaults.string(forKey: GoogleDriveConfig.Keys.accountName)
    }

    // MARK: - Sign-in

    var isConnected: Bool { authState == .connected }

    /// The Client ID as the user would recognise it, for the text field.
    var clientIDText: String {
        clientPrefix.map { GoogleDriveConfig.fullClientID(prefix: $0) } ?? ""
    }

    /// Saves the Client ID and shows Google's sign-in sheet.
    func connect(clientIDText: String) async {
        guard authState != .connecting else { return }
        guard let prefix = GoogleDriveConfig.normalisedClientPrefix(clientIDText) else {
            authMessage = "That doesn't look like a Google Client ID. It should look like 1234567890-abc123.apps.googleusercontent.com"
            return
        }
        let previous = authState
        clientPrefix = prefix
        UserDefaults.standard.set(GoogleDriveConfig.fullClientID(prefix: prefix),
                                  forKey: GoogleDriveConfig.Keys.clientID)
        authMessage = nil
        authState = .connecting

        do {
            // Asks for the delete permission again only if it was switched on.
            try await auth.signIn(clientPrefix: prefix, fullAccess: canDeleteFromDrive)
            UserDefaults.standard.set(false, forKey: GoogleDriveConfig.Keys.needsReconnect)
            listingCache.removeAll()
            authState = .connected
            Haptics.success()
            await refreshAccount(force: true)
        } catch {
            authState = previous == .expired ? .expired : .signedOut
            if !DriveError.isCancellation(error) {
                authMessage = DriveError.message(for: error)
            }
        }
    }

    /// Switches "Allow deleting from Drive" on or off.
    ///
    /// On: shows Google's sheet again, this time asking for permission to
    /// change files, and only switches on if Google grants it. Off: Sonora
    /// stops deleting from Drive at once; the read-only sign-in is asked for
    /// the next time the user connects.
    func setDeleteAllowed(_ on: Bool) async {
        guard on != canDeleteFromDrive, !isChangingPermission else { return }
        let defaults = UserDefaults.standard
        if !on {
            canDeleteFromDrive = false
            defaults.set(false, forKey: GoogleDriveConfig.Keys.deleteAllowed)
            return
        }
        guard let prefix = clientPrefix, authState == .connected else {
            authMessage = DriveError.notConnected.errorDescription
            return
        }
        authMessage = nil
        isChangingPermission = true
        defer { isChangingPermission = false }
        do {
            try await auth.signIn(clientPrefix: prefix, fullAccess: true)
            canDeleteFromDrive = true
            defaults.set(true, forKey: GoogleDriveConfig.Keys.deleteAllowed)
            defaults.set(false, forKey: GoogleDriveConfig.Keys.needsReconnect)
            Haptics.success()
        } catch {
            // The earlier, read-only sign-in is still saved and still works.
            if !DriveError.isCancellation(error) {
                authMessage = DriveError.message(for: error)
            }
        }
    }

    // MARK: - Deleting

    /// The Drive files a downloaded song came from. Usually one; more when
    /// the same song was in Drive twice and one download served for both.
    func driveFileIDs(forLocalPath relativePath: String) -> [String] {
        downloaded.filter { $0.value.relativePath == relativePath }.map(\.key).sorted()
    }

    /// Moves the Drive file(s) behind a downloaded song to the Bin in Drive.
    func moveToBin(localPath relativePath: String) async throws {
        guard canDeleteFromDrive else {
            throw DriveError.api("Deleting from Google Drive is switched off. Switch on “Allow deleting from Drive” on the Google Drive screen.")
        }
        for fileID in driveFileIDs(forLocalPath: relativePath) {
            try await withToken { token in
                try await DriveAPI.moveToBin(fileID: fileID, token: token)
            }
        }
        // The folder listings still show the song.
        listingCache.removeAll()
    }

    /// Call after a downloaded song's file was deleted from the iPhone.
    /// With `keepOffThisPhone` the song is still in Drive, and sync is told
    /// to leave it there instead of downloading it again.
    func forgetDownload(localPath relativePath: String, keepOffThisPhone: Bool) {
        let ids = driveFileIDs(forLocalPath: relativePath)
        guard !ids.isEmpty else { return }
        for id in ids {
            downloaded[id] = nil
            if keepOffThisPhone { ignoredIDs.insert(id) }
        }
        saveIndex()
    }

    /// Signs out. Downloaded music stays on the iPhone.
    func disconnect() async {
        cancelAll()
        accountEmail = nil
        accountName = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: GoogleDriveConfig.Keys.accountEmail)
        defaults.removeObject(forKey: GoogleDriveConfig.Keys.accountName)
        defaults.set(false, forKey: GoogleDriveConfig.Keys.needsReconnect)
        listingCache.removeAll()
        authMessage = nil
        didCheckAccount = false
        authState = clientPrefix == nil ? .notSetUp : .signedOut
        await auth.signOut()
    }

    /// Asks Drive who is signed in. Also the cheapest way to find out early
    /// that the sign-in has expired. Runs once per launch unless forced.
    func refreshAccount(force: Bool = false) async {
        guard authState == .connected, force || !didCheckAccount else { return }
        didCheckAccount = true
        do {
            let info = try await withToken { token in
                try await DriveAPI.account(token: token)
            }
            accountEmail = info.email
            accountName = info.name
            let defaults = UserDefaults.standard
            defaults.set(info.email, forKey: GoogleDriveConfig.Keys.accountEmail)
            defaults.set(info.name, forKey: GoogleDriveConfig.Keys.accountName)
        } catch {
            // Keep whatever name was shown before. An expired sign-in has
            // already been flagged by withToken; a network hiccup just
            // means trying again the next time the screen opens.
            if (error as? DriveError) != .signInExpired {
                didCheckAccount = false
            }
        }
    }

    private func markExpired() {
        guard authState != .expired else { return }
        authState = .expired
        UserDefaults.standard.set(true, forKey: GoogleDriveConfig.Keys.needsReconnect)
        authMessage = DriveError.signInExpired.errorDescription
        // Nothing queued can succeed any more.
        queue.removeAll()
        queuedIDs.removeAll()
        totalCount = finishedCount + activeJobs.count
    }

    /// Runs `work` with a valid access token. If Drive rejects the token,
    /// refreshes it once and tries again.
    private func withToken<T>(_ work: (String) async throws -> T) async throws -> T {
        guard let prefix = clientPrefix else { throw DriveError.notSetUp }
        guard authState == .connected else {
            throw authState == .expired ? DriveError.signInExpired : DriveError.notConnected
        }
        do {
            let token = try await auth.validAccessToken(clientPrefix: prefix)
            do {
                return try await work(token)
            } catch DriveError.unauthorized {
                let fresh = try await auth.refreshedToken(replacing: token, clientPrefix: prefix)
                return try await work(fresh)
            }
        } catch DriveError.signInExpired {
            markExpired()
            throw DriveError.signInExpired
        } catch DriveError.notConnected {
            // The saved sign-in is gone from the Keychain.
            markExpired()
            throw DriveError.signInExpired
        }
    }

    // MARK: - Browsing

    /// What was last loaded for a folder, if anything (no network).
    func cachedListing(of folder: DriveFolderRef) -> [DriveItem]? {
        listingCache[folder.id]
    }

    /// Folders and songs directly inside `folder`.
    func listing(of folder: DriveFolderRef, forceRefresh: Bool) async throws -> [DriveItem] {
        if !forceRefresh, let cached = listingCache[folder.id] { return cached }
        let items = try await withToken { token in
            try await DriveAPI.list(folder: folder, token: token)
        }
        listingCache[folder.id] = items
        return items
    }

    func state(of item: DriveItem) -> DriveItemState {
        if let bytes = activeBytes[item.id] {
            if let size = item.size, size > 0 {
                return .downloading(min(1, Double(bytes) / Double(size)))
            }
            return .downloading(nil)
        }
        if queuedIDs.contains(item.id) { return .queued }
        if downloaded[item.id] != nil { return .downloaded }
        return .notDownloaded
    }

    // MARK: - Starting downloads

    /// Downloads one song.
    func download(_ item: DriveItem, in folder: DriveFolderRef) {
        guard !item.isFolder else { return }
        prepareForNewAction()
        let taskID = UUID()
        lookTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            await self.enqueue([DriveCandidate(item: item, folders: folder.pathComponents)],
                               wifiOnly: false, fromSync: false)
            self.lookTasks[taskID] = nil
            self.settleIfDone()
        }
        updateActivity()
    }

    /// Downloads every song in a folder and in all the folders inside it.
    func downloadFolder(_ folder: DriveFolderRef) {
        guard folder.kind == .folder else { return }
        prepareForNewAction()
        startLooking(in: [folder], wifiOnly: false, markSynced: false)
    }

    /// Looks through every synced folder and downloads what is new or changed.
    func syncNow(wifiOnly: Bool = false, quiet: Bool = false) {
        guard isConnected, !syncedFolders.isEmpty else { return }
        let wasIdle = activity == .idle
        prepareForNewAction()
        if wasIdle { quietSession = quiet }
        startLooking(in: syncedFolders.map(\.folderRef), wifiOnly: wifiOnly, markSynced: true)
    }

    /// Called from SonoraApp when the app opens. Does nothing unless the
    /// user switched "Sync when Sonora opens" on, and then only on Wi-Fi
    /// and when battery saving is not in force.
    static func launchSyncIfEnabled() async {
        guard UserDefaults.standard.bool(forKey: GoogleDriveConfig.Keys.syncOnLaunch) else { return }
        let manager = GoogleDriveManager.shared
        guard manager.isConnected, !manager.syncedFolders.isEmpty, manager.activity == .idle else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              PowerState.mayRunHeavyWork(settings: AppSettings.shared) else { return }
        guard await DriveNetwork.isOnWiFi() else { return }
        manager.syncNow(wifiOnly: true, quiet: true)
    }

    private func prepareForNewAction() {
        guard activity == .idle else { return }
        notice = nil
        failures = []
        cancelRequested = false
        quietSession = false
        networkFailuresInARow = 0
        foundSoFar = 0
    }

    private func startLooking(in folders: [DriveFolderRef], wifiOnly: Bool, markSynced: Bool) {
        let taskID = UUID()
        lookTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            for folder in folders {
                if Task.isCancelled { break }
                do {
                    let candidates = try await self.collect(folder)
                    if Task.isCancelled { break }
                    await self.enqueue(candidates, wifiOnly: wifiOnly, fromSync: markSynced)
                    if markSynced { self.noteSynced(folder.id) }
                } catch {
                    if DriveError.isCancellation(error) { break }
                    self.failures.append(DriveFailure(
                        name: folder.name,
                        message: "Couldn't open this folder. " + DriveError.message(for: error)))
                    if let drive = error as? DriveError, drive == .signInExpired { break }
                }
            }
            self.lookTasks[taskID] = nil
            self.settleIfDone()
        }
        updateActivity()
    }

    /// Every song under `top`, with the folder names leading to each one.
    /// A subfolder that cannot be opened is noted and skipped; only a
    /// failure on `top` itself (or an expired sign-in) stops the walk.
    private func collect(_ top: DriveFolderRef) async throws -> [DriveCandidate] {
        var found: [DriveCandidate] = []
        var pending: [DriveFolderRef] = [top]
        var visited = Set<String>()

        while !pending.isEmpty {
            let folder = pending.removeFirst()
            try Task.checkCancellation()
            // `visited` stops a shortcut loop; the depth limit is a backstop.
            guard visited.insert(folder.id).inserted, folder.pathComponents.count <= 40 else { continue }

            let items: [DriveItem]
            do {
                items = try await listing(of: folder, forceRefresh: true)
            } catch {
                let expired = (error as? DriveError) == .signInExpired
                if folder.id == top.id || expired || DriveError.isCancellation(error) { throw error }
                failures.append(DriveFailure(
                    name: folder.name,
                    message: "Couldn't open this folder. " + DriveError.message(for: error)))
                continue
            }
            for item in items {
                if item.isFolder {
                    pending.append(folder.child(item))
                } else {
                    found.append(DriveCandidate(item: item, folders: folder.pathComponents))
                    foundSoFar += 1
                }
            }
        }
        return found
    }

    /// Works out what really needs downloading and puts it in the queue.
    ///
    /// `fromSync`: an automatic or "Sync Now" pass leaves out songs the user
    /// deleted from the iPhone. Asking for a song or a folder by hand
    /// downloads them again and takes them off that list.
    private func enqueue(_ all: [DriveCandidate], wifiOnly: Bool, fromSync: Bool) async {
        var candidates = all
        if !ignoredIDs.isEmpty {
            if fromSync {
                candidates = all.filter { !ignoredIDs.contains($0.item.id) }
            } else {
                let before = ignoredIDs.count
                for candidate in all { ignoredIDs.remove(candidate.item.id) }
                if ignoredIDs.count != before { saveIndex() }
            }
        }
        guard !candidates.isEmpty else { return }
        let busy = queuedIDs.union(activeJobs.keys)
        let plan = await DrivePlanner.plan(candidates: candidates,
                                           index: downloaded,
                                           busyIDs: busy,
                                           wifiOnly: wifiOnly)
        if Task.isCancelled { return }

        sessionAlready += plan.alreadyHave
        if !plan.adopted.isEmpty {
            for (id, entry) in plan.adopted where downloaded[id] == nil {
                downloaded[id] = entry
                pendingPaths.append(entry.relativePath)
            }
            saveIndex()
        }

        // The queue may have moved on while the plan was being made.
        let jobs = plan.jobs.filter { !queuedIDs.contains($0.id) && activeJobs[$0.id] == nil }
        guard !jobs.isEmpty else { return }

        let needed = jobs.reduce(Int64(0)) { $0 + ($1.expectedSize ?? 0) }
        // Leave some room so the iPhone is not filled to the brim.
        let reserve: Int64 = 300 * 1024 * 1024
        if let free = DriveLocalFolder.freeSpace(), needed + reserve > free {
            let error = DriveError.notEnoughSpace(needed: needed, free: free)
            failures.append(DriveFailure(name: "Not enough space",
                                         message: error.errorDescription ?? ""))
            return
        }

        // Anything queued from here on was asked for after the last "Stop".
        cancelRequested = false
        networkFailuresInARow = 0
        queue.append(contentsOf: jobs)
        queuedIDs.formUnion(jobs.map(\.id))
        totalCount += jobs.count
        bytesPlanned += needed
        startRunnerIfNeeded()
    }

    // MARK: - Running the queue

    private func startRunnerIfNeeded() {
        guard runner == nil, !queue.isEmpty else { return }
        DriveLocalFolder.prepare()
        beginBackgroundTask()
        runner = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<GoogleDriveConfig.maxConcurrentDownloads {
                    group.addTask { [weak self] in
                        await self?.worker()
                    }
                }
            }
            self?.runnerFinished()
        }
        updateActivity()
    }

    /// One of the parallel download lanes: takes the next file until none are left.
    private func worker() async {
        while !Task.isCancelled, !queue.isEmpty {
            let job = queue.removeFirst()
            queuedIDs.remove(job.id)
            await run(job)
        }
    }

    private func run(_ job: DriveJob) async {
        activeJobs[job.id] = job
        activeBytes[job.id] = 0
        let destination = DriveLocalFolder.url.appendingPathComponent(job.relativePath)

        var result = await attempt(job, destination: destination)
        // One more go for a dropped connection; anything else is reported.
        if case .failure(let error) = result, Self.isTransient(error), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                activeBytes[job.id] = 0
                result = await attempt(job, destination: destination)
            }
        }

        activeJobs[job.id] = nil
        activeBytes[job.id] = nil
        finishedCount += 1
        bytesFinished += job.expectedSize ?? 0

        switch result {
        case .success(let size):
            if let expected = job.expectedSize, expected > 0, size != expected {
                // Short or padded: not the file Drive described.
                try? FileManager.default.removeItem(at: destination)
                downloaded[job.id] = nil
                failures.append(DriveFailure(name: job.name,
                                             message: "The download was incomplete. Try again."))
            } else {
                downloaded[job.id] = DriveIndexEntry(relativePath: job.relativePath,
                                                     size: size,
                                                     md5: job.md5,
                                                     modifiedTime: job.modifiedTime)
                pendingPaths.append(job.relativePath)
                sessionAdded += 1
            }
            networkFailuresInARow = 0
            unsavedChanges += 1
            if unsavedChanges >= 10 { saveIndex() }
        case .failure(let error):
            if DriveError.isCancellation(error) || Task.isCancelled {
                // Stopped by the user: not a failure worth listing.
                break
            }
            if let drive = error as? DriveError, drive == .signInExpired {
                if !failures.contains(where: { $0.name == "Google Drive" }) {
                    failures.append(DriveFailure(name: "Google Drive",
                                                 message: DriveError.message(for: error)))
                }
            } else {
                failures.append(DriveFailure(name: job.name, message: DriveError.message(for: error)))
                if Self.isNetworkTrouble(error) { noteNetworkFailure() }
            }
        }
    }

    /// After a few network failures in a row the rest of the queue is
    /// dropped: the connection is gone, and the files can be fetched with
    /// one tap later (what is already downloaded is skipped).
    private func noteNetworkFailure() {
        networkFailuresInARow += 1
        guard networkFailuresInARow >= 4, !queue.isEmpty else { return }
        let dropped = queue.count
        queue.removeAll()
        queuedIDs.removeAll()
        totalCount = finishedCount + activeJobs.count
        failures.append(DriveFailure(
            name: "Connection lost",
            message: "\(dropped) more song\(dropped == 1 ? " was" : "s were") not downloaded. Try again when the connection is back."))
    }

    private func attempt(_ job: DriveJob, destination: URL) async -> Result<Int64, Error> {
        let fileID = job.id
        let wifiOnly = job.wifiOnly
        do {
            let size = try await withToken { token in
                try await DriveAPI.download(fileID: fileID,
                                            token: token,
                                            destination: destination,
                                            wifiOnly: wifiOnly,
                                            progress: { [weak self] bytes in
                    Task { @MainActor [weak self] in
                        self?.noteProgress(fileID, bytes)
                    }
                })
            }
            return .success(size)
        } catch {
            return .failure(error)
        }
    }

    private func noteProgress(_ fileID: String, _ bytes: Int64) {
        // A late report for a file that already finished is ignored.
        guard let current = activeBytes[fileID], bytes > current else { return }
        activeBytes[fileID] = bytes
    }

    /// Worth one more try straight away.
    private static func isTransient(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return url.code == .networkConnectionLost || url.code == .timedOut
    }

    private static func isNetworkTrouble(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let drive = error as? DriveError, case .network = drive { return true }
        return false
    }

    private func runnerFinished() {
        runner = nil
        endBackgroundTask()
        if !queue.isEmpty {
            // Something was added while the last files were finishing (a
            // "Stop" empties the queue itself, so this is new work).
            startRunnerIfNeeded()
            return
        }
        settleIfDone()
    }

    /// Stops looking and downloading. Files that already finished are kept.
    func cancelAll() {
        guard activity == .looking || activity == .downloading else { return }
        cancelRequested = true
        for task in lookTasks.values { task.cancel() }
        queue.removeAll()
        queuedIDs.removeAll()
        totalCount = finishedCount + activeJobs.count
        runner?.cancel()
    }

    // MARK: - Finishing

    private func updateActivity() {
        let next: Activity
        if runner != nil {
            next = .downloading
        } else if !lookTasks.isEmpty {
            next = .looking
        } else if isFinishing {
            next = .finishing
        } else {
            next = .idle
        }
        if next != activity { activity = next }
    }

    /// When nothing is looking or downloading any more: add the new songs to
    /// the library and say how it went.
    private func settleIfDone() {
        updateActivity()
        guard runner == nil, lookTasks.isEmpty, !isFinishing else { return }
        isFinishing = true
        updateActivity()
        // A fresh task on purpose: the one that got us here may have been
        // cancelled, and reading tags in a cancelled task fails.
        Task { [weak self] in
            await self?.finishSession()
        }
    }

    private func finishSession() async {
        saveIndex()
        await addPendingToLibrary()
        await refreshStorage()
        isFinishing = false

        // More work arrived while the library was being updated; this runs
        // again when that work is done.
        if runner != nil || !lookTasks.isEmpty {
            updateActivity()
            return
        }
        if !pendingPaths.isEmpty {
            settleIfDone()
            return
        }

        let nothingToReport = quietSession && sessionAdded == 0 && failures.isEmpty
        notice = nothingToReport ? nil : summary()
        if sessionAdded > 0 { Haptics.success() }
        quietSession = false
        totalCount = 0
        finishedCount = 0
        bytesPlanned = 0
        bytesFinished = 0
        sessionAdded = 0
        sessionAlready = 0
        foundSoFar = 0
        cancelRequested = false
        updateActivity()
    }

    private func summary() -> String? {
        let failed = failures.count
        func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

        var parts: [String] = []
        if sessionAdded > 0 {
            parts.append("Added \(songs(sessionAdded)) to your library.")
        }
        if cancelRequested {
            parts.insert("Stopped.", at: 0)
        } else if sessionAdded == 0, failed == 0 {
            parts.append(sessionAlready > 0
                         ? "Everything is already on your iPhone."
                         : "No songs found there.")
        }
        if failed > 0 {
            parts.append((failed == 1 ? "1 problem." : "\(failed) problems.")
                         + " Details are on the Google Drive screen.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Puts newly downloaded files into the music library.
    private func addPendingToLibrary() async {
        let paths = pendingPaths
        pendingPaths = []
        guard let library = AppServices.library else { return }
        let folderName = GoogleDriveConfig.localFolderName
        let rootMissing = library.appFolderRoot(relativePath: folderName) == nil

        // Nothing new, and the folder is already (or need not be) in the library.
        if paths.isEmpty && (!rootMissing || downloaded.isEmpty) { return }

        DriveLocalFolder.prepare()
        let rootID = library.ensureAppFolderRoot(relativePath: folderName, displayName: folderName)
        if rootMissing {
            // First time (or the library index was erased): scan the whole
            // folder so everything already downloaded shows up.
            await library.rescan(rootID: rootID)
        } else {
            // Later: read only the new files, leaving the rest of the
            // library, the queue and the playlists untouched.
            await library.indexFiles(rootID: rootID, relativePaths: paths)
        }
    }

    // MARK: - Progress for the UI

    /// 0...1 across the whole batch, by bytes where Drive told us the sizes.
    var overallFraction: Double {
        if bytesPlanned > 0 {
            var done = bytesFinished
            for (id, bytes) in activeBytes {
                let cap = activeJobs[id]?.expectedSize ?? bytes
                done += min(bytes, cap)
            }
            return max(0, min(1, Double(done) / Double(bytesPlanned)))
        }
        guard totalCount > 0 else { return 0 }
        return max(0, min(1, Double(finishedCount) / Double(totalCount)))
    }

    /// "12 of 40 · 35%"
    var progressLine: String {
        let percent = Int((overallFraction * 100).rounded())
        return "\(min(finishedCount, totalCount)) of \(totalCount) · \(percent)%"
    }

    /// The name of a file downloading right now, for the progress bar.
    var currentFileName: String? {
        activeJobs.values.map(\.name).sorted().first
    }

    // MARK: - Synced folders

    func isSynced(_ folder: DriveFolderRef) -> Bool {
        syncedFolders.contains { $0.id == folder.id }
    }

    /// Adds a folder to the synced list (and downloads it now), or takes it
    /// off the list. Taking it off never deletes music.
    func setSynced(_ folder: DriveFolderRef, _ on: Bool) {
        guard folder.kind == .folder else { return }
        if on {
            guard !isSynced(folder) else { return }
            syncedFolders.append(DriveSyncedFolder(id: folder.id,
                                                   name: folder.name,
                                                   pathComponents: folder.pathComponents,
                                                   displayPath: folder.displayPath,
                                                   lastSynced: nil))
            saveIndex()
            prepareForNewAction()
            startLooking(in: [folder], wifiOnly: false, markSynced: true)
        } else {
            syncedFolders.removeAll { $0.id == folder.id }
            saveIndex()
        }
    }

    func removeSyncedFolders(at offsets: IndexSet) {
        let valid = IndexSet(offsets.filter { syncedFolders.indices.contains($0) })
        guard !valid.isEmpty else { return }
        syncedFolders.remove(atOffsets: valid)
        saveIndex()
    }

    private func noteSynced(_ folderID: String) {
        guard let idx = syncedFolders.firstIndex(where: { $0.id == folderID }) else { return }
        syncedFolders[idx].lastSynced = Date()
        saveIndex()
    }

    func setSyncOnLaunch(_ on: Bool) {
        syncOnLaunch = on
        UserDefaults.standard.set(on, forKey: GoogleDriveConfig.Keys.syncOnLaunch)
    }

    // MARK: - Storage

    /// Measures the Drive folder and forgets files that are no longer on
    /// disk (deleted through the Files app, for instance).
    func refreshStorage() async {
        let result = await DriveLocalFolder.audit(index: downloaded)
        storageBytes = result.bytes
        guard !result.missing.isEmpty else { return }
        let root = DriveLocalFolder.url
        var changed = false
        for id in result.missing where activeJobs[id] == nil {
            // Checked again here: a download may have landed since the audit.
            guard let entry = downloaded[id],
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.relativePath).path)
            else { continue }
            downloaded[id] = nil
            changed = true
        }
        if changed { saveIndex() }
    }

    /// Deletes every song downloaded from Drive and takes them out of the
    /// library. The synced-folder list is kept, but automatic sync is
    /// switched off so the music does not quietly come back.
    func removeAllDownloads() async {
        cancelAll()
        // Let anything in flight wind down first, so a file cannot land (or
        // be added to the library) after the folder is gone.
        var waited = 0
        while activity != .idle, waited < 300 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        downloaded = [:]
        pendingPaths = []
        ignoredIDs = []
        setSyncOnLaunch(false)
        for i in syncedFolders.indices { syncedFolders[i].lastSynced = nil }
        saveIndex()

        let folder = DriveLocalFolder.url
        let staging = DriveAPI.stagingFolder
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: staging)
        }.value

        if let library = AppServices.library,
           let root = library.appFolderRoot(relativePath: GoogleDriveConfig.localFolderName) {
            library.removeRoot(root)
            // The queue may point at songs that no longer exist.
            AppServices.player?.pruneQueue()
        }
        storageBytes = 0
        failures = []
        notice = "Removed the music downloaded from Google Drive."
    }

    func clearFailures() {
        failures = []
    }

    private func saveIndex() {
        unsavedChanges = 0
        DriveIndexStore.save(DriveIndexSnapshot(files: downloaded,
                                                syncedFolders: syncedFolders,
                                                ignored: ignoredIDs.isEmpty ? nil : ignoredIDs.sorted()))
    }

    // MARK: - Background grace time

    /// Asks iOS for a little extra time if the user leaves the app mid-download,
    /// so files in flight can finish instead of being cut off at once.
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sonora Drive downloads") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
