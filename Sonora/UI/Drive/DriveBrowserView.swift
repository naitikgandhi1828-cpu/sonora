//
//  DriveBrowserView.swift
//  Sonora
//
//  Shows one Google Drive folder: the folders inside it (tap to go deeper)
//  and the songs Sonora can play (tap to download). The whole folder can be
//  downloaded in one go, or kept in sync.
//

import SwiftUI

struct DriveBrowserView: View {

    let folder: DriveFolderRef

    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var drive = GoogleDriveManager.shared

    @State private var items: [DriveItem] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var confirmDownloadFolder = false

    private var subfolders: [DriveItem] { items.filter { $0.isFolder } }
    private var songs: [DriveItem] { items.filter { !$0.isFolder } }

    /// "Shared with me" is a list, not a folder, so it cannot be downloaded
    /// or synced as a whole; the folders inside it can.
    private var isRealFolder: Bool { folder.kind == .folder }

    var body: some View {
        List {
            if isRealFolder { actionsSection }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(themes.theme.textPrimary)
                    Button("Try Again") {
                        Task { await load(force: true) }
                    }
                }
                .themedRow(themes.theme)
            }

            if isLoading && !hasLoaded {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(themes.theme.textSecondary)
                    }
                }
                .themedRow(themes.theme)
            }

            if !subfolders.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { item in
                        NavigationLink {
                            DriveBrowserView(folder: folder.child(item))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(themes.accent)
                                    .frame(width: 24)
                                Text(item.name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(themes.theme.textPrimary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .themedRow(themes.theme)
            }

            if !songs.isEmpty {
                Section {
                    ForEach(songs) { item in
                        songRow(item)
                    }
                } header: {
                    Text(songs.count == 1 ? "1 Song" : "\(songs.count) Songs")
                } footer: {
                    Text("Tap a song to download it. A tick means it is already on your iPhone.")
                }
                .themedRow(themes.theme)
            }

            if hasLoaded && items.isEmpty && loadError == nil {
                Section {
                    Text("No folders or playable songs here.")
                        .font(.system(size: 14))
                        .foregroundStyle(themes.theme.textSecondary)
                }
                .themedRow(themes.theme)
            }
        }
        .themedList(themes.theme)
        .themedNavBar(themes.theme)
        .tint(themes.accent)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { DriveProgressBanner() }
        // Room for the mini player, which floats over the bottom of the screen.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 60) }
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isRealFolder {
                    Menu {
                        Button {
                            confirmDownloadFolder = true
                        } label: {
                            Label("Download This Folder", systemImage: "arrow.down.circle")
                        }
                        Button {
                            drive.setSynced(folder, !drive.isSynced(folder))
                            Haptics.select()
                        } label: {
                            Label(drive.isSynced(folder) ? "Stop Syncing This Folder" : "Keep This Folder Synced",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            Task { await load(force: true) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(themes.accent)
                }
            }
        }
        .confirmationDialog("Download “\(folder.name)”?",
                            isPresented: $confirmDownloadFolder,
                            titleVisibility: .visible) {
            Button("Download All Songs") {
                drive.downloadFolder(folder)
                Haptics.tap()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sonora downloads every song in this folder and in the folders inside it. Songs you already have are skipped. Keep Sonora open until it finishes.")
        }
    }

    // MARK: Sections

    private var actionsSection: some View {
        Section {
            Button {
                confirmDownloadFolder = true
            } label: {
                Label("Download This Folder", systemImage: "arrow.down.circle")
            }

            Toggle(isOn: Binding(
                get: { drive.isSynced(folder) },
                set: { on in
                    drive.setSynced(folder, on)
                    Haptics.select()
                })) {
                Label("Keep This Folder Synced", systemImage: "arrow.triangle.2.circlepath")
            }
        } footer: {
            Text(folder.displayPath)
        }
        .themedRow(themes.theme)
    }

    private func songRow(_ item: DriveItem) -> some View {
        let state = drive.state(of: item)
        return Button {
            if state == .notDownloaded {
                drive.download(item, in: folder)
                Haptics.tap()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .foregroundStyle(themes.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15))
                        .foregroundStyle(themes.theme.textPrimary)
                        .lineLimit(2)
                    Text(detail(for: item, state: state))
                        .font(.system(size: 11))
                        .foregroundStyle(themes.theme.textSecondary)
                }
                Spacer(minLength: 8)
                DriveStateIcon(state: state)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(for item: DriveItem, state: DriveItemState) -> String {
        let size = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        var parts: [String] = []
        if let size { parts.append(size) }
        switch state {
        case .notDownloaded:
            break
        case .queued:
            parts.append("Waiting")
        case .downloading(let fraction):
            if let fraction {
                parts.append("Downloading \(Int((fraction * 100).rounded()))%")
            } else {
                parts.append("Downloading")
            }
        case .downloaded:
            parts.append("On this iPhone")
        }
        return parts.isEmpty ? "Song" : parts.joined(separator: " · ")
    }

    // MARK: Loading

    private func load(force: Bool) async {
        if !force, let cached = drive.cachedListing(of: folder) {
            items = cached
            hasLoaded = true
            loadError = nil
            return
        }
        isLoading = true
        do {
            let fresh = try await drive.listing(of: folder, forceRefresh: force)
            items = fresh
            hasLoaded = true
            loadError = nil
        } catch {
            // Leaving the screen cancels the request; that is not a problem to show.
            if !DriveError.isCancellation(error) {
                loadError = DriveError.message(for: error)
            }
        }
        isLoading = false
    }
}

// MARK: - State icon

/// The little mark at the end of a song row: download arrow, waiting,
/// a progress ring, or a tick.
struct DriveStateIcon: View {

    let state: DriveItemState

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        Group {
            switch state {
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(themes.accent)
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(themes.theme.textSecondary)
            case .downloading(let fraction):
                if let fraction {
                    ZStack {
                        Circle()
                            .stroke(themes.theme.separator, lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.03, min(1, fraction))))
                            .stroke(themes.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 18, height: 18)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .downloaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(themes.accent)
            }
        }
        .font(.system(size: 20))
        .frame(width: 28, height: 28)
    }
}
