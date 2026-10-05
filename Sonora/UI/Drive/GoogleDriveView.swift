//
//  GoogleDriveView.swift
//  Sonora
//
//  The Google Drive screen: set-up and sign-in when not connected; account,
//  browsing, synced folders and storage when connected.
//

import SwiftUI
import UIKit

struct GoogleDriveView: View {

    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var drive = GoogleDriveManager.shared

    @State private var clientIDDraft = ""
    @State private var showSetupSteps = false
    @State private var didPrepare = false
    @State private var confirmDisconnect = false
    @State private var confirmRemoveMusic = false
    @FocusState private var clientIDFocused: Bool

    private var isBusy: Bool { drive.activity != .idle }

    var body: some View {
        List {
            if drive.isConnected {
                accountSection
                browseSection
                syncedSection
            } else {
                setupSection
                connectSection
            }
            if !drive.failures.isEmpty { problemsSection }
            if drive.isConnected || !drive.downloaded.isEmpty || drive.storageBytes > 0 {
                storageSection
            }
            if drive.isConnected { disconnectSection }
        }
        .themedList(themes.theme)
        .themedNavBar(themes.theme)
        .tint(themes.accent)
        .navigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { DriveProgressBanner() }
        // Room for the mini player, which floats over the bottom of the screen.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 60) }
        .task {
            if !didPrepare {
                didPrepare = true
                clientIDDraft = drive.clientIDText
                // The steps start open only for someone who has never set this up.
                showSetupSteps = drive.authState == .notSetUp
            }
            await drive.refreshStorage()
            await drive.refreshAccount()
        }
        .confirmationDialog("Disconnect Google Drive?",
                            isPresented: $confirmDisconnect,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task { await drive.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sonora will forget this Google account. Music you already downloaded stays on your iPhone and keeps playing.")
        }
        .confirmationDialog("Remove downloaded Drive music?",
                            isPresented: $confirmRemoveMusic,
                            titleVisibility: .visible) {
            Button("Remove Music", role: .destructive) {
                Task { await drive.removeAllDownloads() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the songs Sonora downloaded from Google Drive and frees the space. Nothing in your Drive is touched, and you can download them again any time.")
        }
    }

    // MARK: Not connected

    private var setupSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showSetupSteps) {
                step(1, "On a computer, open console.cloud.google.com and create a project (or open one you already have).")
                step(2, "Go to APIs & Services → Library, find “Google Drive API” and press Enable.")
                step(3, "Go to OAuth consent screen. Choose External, and add your own Gmail address as a test user.")
                step(4, "Go to Credentials → Create credentials → OAuth client ID. Choose the type iOS. Any bundle ID will do.")
                step(5, "Copy the Client ID it shows and paste it below.")
            } label: {
                Label("How to get a Client ID", systemImage: "list.number")
                    .foregroundStyle(themes.theme.textPrimary)
            }
        } header: {
            Text("One-time set-up")
        } footer: {
            Text("You can paste the same Client ID you use in SpendLog — just make sure “Google Drive API” is enabled in that project (step 2).\n\nWhile the consent screen says “Testing”, Google ends the sign-in every 7 days and you connect again. Set it to “In production” to stop that.\n\nGoogle may warn that the app isn't verified. That is normal for a personal app: tap Advanced, then “Go to” your app's name.")
        }
        .themedRow(themes.theme)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themes.accent)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(themes.theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var connectSection: some View {
        Section {
            if drive.authState == .expired {
                Label("Google sign-in expired — connect again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
            }

            TextField("Google OAuth Client ID", text: $clientIDDraft, axis: .vertical)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($clientIDFocused)
                .foregroundStyle(themes.theme.textPrimary)

            Button {
                if let text = UIPasteboard.general.string {
                    clientIDDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    Haptics.select()
                }
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
            }

            Button {
                clientIDFocused = false
                Haptics.tap()
                Task { await drive.connect(clientIDText: clientIDDraft) }
            } label: {
                HStack {
                    Label(drive.authState == .expired ? "Connect Again" : "Connect Google Drive",
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if drive.authState == .connecting { ProgressView() }
                }
            }
            .disabled(drive.authState == .connecting
                      || clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let message = drive.authMessage, drive.authState != .expired {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Client ID")
        } footer: {
            Text("It looks like 1234567890-abc123.apps.googleusercontent.com. Sonora only asks to read your Drive. It can delete a song there only if you later switch on “Allow deleting from Drive”.")
        }
        .themedRow(themes.theme)
    }

    // MARK: Connected

    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(themes.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.accountName ?? "Connected")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(themes.theme.textPrimary)
                    if let email = drive.accountEmail {
                        Text(email)
                            .font(.system(size: 12))
                            .foregroundStyle(themes.theme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Toggle(isOn: Binding(get: { drive.canDeleteFromDrive },
                                 set: { on in Task { await drive.setDeleteAllowed(on) } })) {
                HStack(spacing: 8) {
                    Text("Allow deleting from Drive")
                        .foregroundStyle(themes.theme.textPrimary)
                    if drive.isChangingPermission { ProgressView().controlSize(.small) }
                }
            }
            .disabled(drive.isChangingPermission)

            if let message = drive.authMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        } footer: {
            Text(drive.canDeleteFromDrive
                 ? "“Delete Song” can now move a song to the Bin in Google Drive, where Google keeps it for 30 days. Sonora never deletes anything in Drive by itself."
                 : "Off: Sonora can only read your Drive. Switch this on if you want “Delete Song” to remove a song from Google Drive too. Google will ask you to sign in again and allow it.")
        }
        .themedRow(themes.theme)
    }

    private var browseSection: some View {
        Section {
            NavigationLink {
                DriveBrowserView(folder: .myDrive)
            } label: {
                Label("My Drive", systemImage: "folder.fill")
            }
            NavigationLink {
                DriveBrowserView(folder: .sharedWithMe)
            } label: {
                Label("Shared with me", systemImage: "person.2.fill")
            }
        } header: {
            Text("Browse Drive")
        } footer: {
            Text("Open a folder, then tap a song to download it, or download the whole folder. Downloaded songs appear in your library and play without internet.\n\nVideos (.mp4, .m4v, .mov) are saved as audio: Sonora downloads the video, keeps only its sound and removes the video from your iPhone. The video in Google Drive is never changed.")
        }
        .foregroundStyle(themes.theme.textPrimary)
        .themedRow(themes.theme)
    }

    private var syncedSection: some View {
        Section {
            if drive.syncedFolders.isEmpty {
                Text("No synced folders yet. Open a folder in Browse and switch on “Keep this folder synced”.")
                    .font(.system(size: 13))
                    .foregroundStyle(themes.theme.textSecondary)
            } else {
                ForEach(drive.syncedFolders) { folder in
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(themes.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                                .font(.system(size: 15))
                                .foregroundStyle(themes.theme.textPrimary)
                            Text(syncedDetail(folder))
                                .font(.system(size: 11))
                                .foregroundStyle(themes.theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                .onDelete { offsets in
                    drive.removeSyncedFolders(at: offsets)
                }

                Button {
                    drive.syncNow()
                    Haptics.tap()
                } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)
            }

            Toggle("Sync when Sonora opens (Wi-Fi only)", isOn: Binding(
                get: { drive.syncOnLaunch },
                set: { on in
                    drive.setSyncOnLaunch(on)
                    Haptics.select()
                }))
        } header: {
            Text("Synced Folders")
        } footer: {
            Text("Sync looks in these folders and downloads songs that are new or have changed. Songs you delete from Drive stay on your iPhone. Swipe a folder left to stop syncing it — its music is kept.")
        }
        .themedRow(themes.theme)
    }

    private func syncedDetail(_ folder: DriveSyncedFolder) -> String {
        guard let date = folder.lastSynced else { return folder.displayPath }
        return "\(folder.displayPath) · synced \(date.formatted(.relative(presentation: .named)))"
    }

    private var problemsSection: some View {
        Section {
            ForEach(drive.failures.prefix(25)) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(themes.theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(failure.message)
                        .font(.system(size: 12))
                        .foregroundStyle(themes.theme.textSecondary)
                }
            }
            if drive.failures.count > 25 {
                Text("…and \(drive.failures.count - 25) more")
                    .font(.system(size: 12))
                    .foregroundStyle(themes.theme.textSecondary)
            }
            Button("Clear List") { drive.clearFailures() }
        } header: {
            Text("Problems")
        } footer: {
            Text("Songs that failed are simply tried again the next time you download or sync.")
        }
        .themedRow(themes.theme)
    }

    private var storageSection: some View {
        Section {
            HStack {
                Text("Downloaded from Drive")
                    .foregroundStyle(themes.theme.textPrimary)
                Spacer()
                Text(storageText)
                    .foregroundStyle(themes.theme.textSecondary)
            }
            Button("Remove Downloaded Drive Music", role: .destructive) {
                confirmRemoveMusic = true
            }
            .disabled(drive.downloaded.isEmpty && drive.storageBytes == 0)
        } header: {
            Text("Storage")
        } footer: {
            Text("The songs are kept in the “Google Drive” folder inside Sonora's folder in the Files app.")
        }
        .themedRow(themes.theme)
    }

    private var storageText: String {
        let count = drive.downloaded.count
        let songs = count == 1 ? "1 song" : "\(count) songs"
        let size = ByteCountFormatter.string(fromByteCount: drive.storageBytes, countStyle: .file)
        return "\(songs) · \(size)"
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect Google Drive", role: .destructive) {
                confirmDisconnect = true
            }
        } footer: {
            Text("Client ID: \(drive.clientIDText)")
                .font(.system(size: 11, design: .monospaced))
        }
        .themedRow(themes.theme)
    }
}

// MARK: - Progress banner

/// Sits under the navigation bar on every Drive screen while something is
/// happening, and shows how the last download went afterwards.
struct DriveProgressBanner: View {

    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var drive = GoogleDriveManager.shared

    var body: some View {
        if drive.activity != .idle {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if drive.activity != .downloading {
                        ProgressView().controlSize(.small).tint(themes.accent)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if drive.activity == .looking || drive.activity == .downloading {
                        Button("Stop") {
                            drive.cancelAll()
                            Haptics.tap()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(themes.accent)
                    }
                }
                if drive.activity == .downloading {
                    ProgressView(value: drive.overallFraction).tint(themes.accent)
                    if let name = drive.currentFileName {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundStyle(themes.theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(themes.theme.textPrimary)
            .background(themes.theme.surfaceElevated)
            .overlay(alignment: .bottom) {
                Rectangle().fill(themes.theme.separator).frame(height: 0.5)
            }
        } else if let notice = drive.notice {
            HStack(spacing: 8) {
                Image(systemName: drive.failures.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(themes.accent)
                Text(notice)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    drive.notice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(themes.theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(themes.theme.textPrimary)
            .background(themes.theme.surfaceElevated)
            .overlay(alignment: .bottom) {
                Rectangle().fill(themes.theme.separator).frame(height: 0.5)
            }
        }
    }

    private var title: String {
        switch drive.activity {
        case .looking:
            if drive.foundSoFar > 0 {
                return "Looking through folders… \(drive.foundSoFar) song\(drive.foundSoFar == 1 ? "" : "s") found"
            }
            return "Looking in Google Drive…"
        case .downloading:
            return "Downloading \(drive.progressLine)"
        case .finishing:
            return "Adding songs to your library…"
        case .idle:
            return ""
        }
    }
}
