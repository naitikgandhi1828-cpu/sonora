//
//  LibraryHomeView.swift
//  Sonora
//
//  Landing screen: quick actions, recently played and shortcuts into the
//  various browse modes.
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryHomeView: View {

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager

    @State private var showFolderPicker = false
    @State private var showFilePicker = false
    @State private var showGoogleDrive = false
    @State private var showDuplicateReview = false
    @State private var importMessage: String?

    /// The songs behind "Recently Played" that are still in the library.
    private var recentTracks: [Track] {
        library.tracks(ids: Array(library.recentlyPlayedIDs.prefix(20)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty && !library.isScanning {
                    EmptyStateView(symbol: "folder.badge.plus",
                                   title: "No music yet",
                                   message: "Add a folder from Files (iCloud Drive, a USB drive, or On My iPhone) and Sonora will index everything inside it.",
                                   actionTitle: "Add Folder",
                                   action: { showFolderPicker = true })
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themes.theme.background.ignoresSafeArea())
            .themedNavBar(themes.theme)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showFolderPicker = true } label: {
                            Label("Add Folder…", systemImage: "folder.badge.plus")
                        }
                        Button { showFilePicker = true } label: {
                            Label("Add Files…", systemImage: "doc.badge.plus")
                        }
                        Button { showGoogleDrive = true } label: {
                            Label("Add from Google Drive", systemImage: "icloud.and.arrow.down")
                        }
                        Divider()
                        Button {
                            Task { await library.rescanAll() }
                        } label: {
                            Label("Rescan Everything", systemImage: "arrow.clockwise")
                        }
                        .disabled(library.roots.isEmpty || library.isScanning)
                        Button {
                            Task {
                                let result = await library.importDocumentsFolder()
                                importMessage = Self.importSummary(result)
                            }
                        } label: {
                            Label("Import from Sonora Folder", systemImage: "square.and.arrow.down")
                        }
                        .disabled(library.isScanning)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .tint(themes.accent)
                }
            }
            .navigationDestination(isPresented: $showGoogleDrive) {
                GoogleDriveView()
            }
            .sheet(isPresented: $showDuplicateReview) {
                DuplicateReviewView().themedSheet(themes)
            }
            .alert("Sonora Folder",
                   isPresented: Binding(get: { importMessage != nil },
                                        set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await library.addRoot(url: url) }
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await library.importFiles(urls: urls) }
                }
            }
        }
    }

    /// One sentence saying what "Import from Sonora Folder" did.
    private static func importSummary(_ result: MediaLibrary.SonoraFolderResult) -> String {
        if result.added > 0 {
            return "Added \(result.added) song\(result.added == 1 ? "" : "s") from the Sonora folder."
        }
        if result.total == 0 {
            return "The Sonora folder has no music in it yet. In the Files app, open On My iPhone › Sonora, copy your songs or folders of songs there, then tap this again."
        }
        if result.removed > 0 {
            return "Nothing new. \(result.removed) song\(result.removed == 1 ? "" : "s") no longer in the folder \(result.removed == 1 ? "was" : "were") taken out of the library."
        }
        return "Nothing new. All \(result.total) song\(result.total == 1 ? "" : "s") in the Sonora folder are already in your library."
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if library.isScanning { scanBanner }
                if !library.duplicateQuestions.isEmpty {
                    DuplicateBanner(count: library.duplicateQuestions.count) {
                        showDuplicateReview = true
                    }
                }
                quickActions
                // Only when there is something to show: the heading alone
                // used to sit on top of "Browse" with nothing under it.
                if !recentTracks.isEmpty { recentSection }
                browseGrid
                statsFooter
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 100)
        }
    }

    private var scanBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().controlSize(.small).tint(themes.accent)
                Text("Scanning…").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Stop") { library.cancelScan() }
                    .font(.system(size: 12))
                    .foregroundStyle(themes.accent)
            }
            ProgressView(value: library.scanProgress).tint(themes.accent)
            Text(library.scanStatus)
                .font(.system(size: 11))
                .foregroundStyle(themes.theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            actionButton("Shuffle All", "shuffle") {
                let ids = library.tracks.map(\.id).shuffled()
                settings.shuffleMode = .tracks
                player.play(trackIDs: ids, sourceName: "Shuffle All")
                Haptics.tap()
            }
            actionButton("Recently Added", "clock.arrow.circlepath") {
                let ids = library.tracks
                    .sorted { $0.dateAdded > $1.dateAdded }
                    .prefix(100).map(\.id)
                player.play(trackIDs: Array(ids), sourceName: "Recently Added")
                Haptics.tap()
            }
        }
    }

    private func actionButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(themes.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(themes.accent)
        }
        .buttonStyle(.plain)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recently Played")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentTracks) { track in
                        Button {
                            player.play(trackIDs: [track.id], sourceName: "Recently Played")
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(key: track.artworkKey, size: 108, cornerRadius: 10)
                                Text(track.displayTitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(track.displayArtist)
                                    .font(.system(size: 11))
                                    .foregroundStyle(themes.theme.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 108)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(themes.theme.textPrimary)
                    }
                }
            }
        }
    }

    private var browseGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Browse")
            VStack(spacing: 0) {
                navRow("Folders", "folder", "\(library.roots.count) root\(library.roots.count == 1 ? "" : "s")") {
                    FolderBrowserView(node: library.folderTree())
                }
                divider
                navRow("Albums", "square.stack", "\(library.albums.count)") {
                    AlbumsView()
                }
                divider
                navRow("Artists", "music.mic", "\(library.artists.count)") {
                    ArtistsView()
                }
                divider
                navRow("Genres", "guitars", "\(library.genres.count)") {
                    GenresView()
                }
                divider
                navRow("All Tracks", "music.note.list", "\(library.tracks.count)") {
                    TrackListView(title: "All Tracks", trackIDs: library.tracks.map(\.id))
                }
                divider
                navRow("Recently Added", "clock.arrow.circlepath", "Newest first") {
                    TrackListView(title: "Recently Added",
                                  trackIDs: library.recentlyAddedIDs(),
                                  keepsGivenOrder: true)
                }
                divider
                navRow("Playlists", "text.badge.plus", "\(library.playlists.count)") {
                    PlaylistsView()
                }
            }
            .cardBackground(themes.theme)
        }
    }

    private var divider: some View {
        Rectangle().fill(themes.theme.separator).frame(height: 0.5).padding(.leading, 52)
    }

    private func navRow<Destination: View>(_ title: String,
                                           _ symbol: String,
                                           _ detail: String,
                                           @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .frame(width: 24)
                    .foregroundStyle(themes.accent)
                Text(title).font(.system(size: 15))
                Spacer()
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(themes.theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(themes.theme.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var statsFooter: some View {
        VStack(spacing: 3) {
            Text("\(library.tracks.count) tracks · \(library.totalDuration.longFormat) · \(library.totalBytes.byteSize)")
            if !library.lastScanSkipped.isEmpty {
                Text("\(library.lastScanSkipped.count) file(s) skipped — format not supported by iOS")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(themes.theme.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}
