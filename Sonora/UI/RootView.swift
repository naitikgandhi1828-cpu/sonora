//
//  RootView.swift
//  Sonora
//
//  Tab shell with the persistent mini player docked above the tab bar.
//

import SwiftUI
import UIKit

struct RootView: View {

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager

    @State private var selectedTab = 0
    @State private var showFullPlayer = false
    @State private var showErrorAlert = false
    /// True while the on-screen keyboard is up. The mini player is taken
    /// away for that time: it is pinned to the bottom of the screen, so the
    /// keyboard used to push it up into the middle of the list being typed
    /// into, where it covered the rows.
    @State private var keyboardIsUp = false
    @State private var showDuplicateReview = false
    /// Sonora brings the question up by itself once per launch; after that
    /// the card on the Library screen is the way in.
    @State private var askedAboutDuplicates = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                LibraryHomeView()
                    .themedTabBar(themes.theme)
                    .tabItem { Label("Library", systemImage: "music.note.house") }
                    .tag(0)

                SearchView()
                    .themedTabBar(themes.theme)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(1)

                NavigationStack { QueueContentView() }
                    .themedTabBar(themes.theme)
                    .tabItem { Label("Queue", systemImage: "list.bullet") }
                    .tag(2)

                SettingsView()
                    .themedTabBar(themes.theme)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(3)
            }
            .tint(themes.accent)

            if player.currentTrack != nil, !keyboardIsUp {
                MiniPlayerView(showFullPlayer: $showFullPlayer)
                    .padding(.bottom, 49)   // sits above the tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(themes.theme.background.ignoresSafeArea())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.currentTrack?.id)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsUp = false
        }
        .fullScreenCover(isPresented: $showFullPlayer) {
            NowPlayingView()
                .themedSheet(themes)
        }
        .preferredColorScheme(themes.colorScheme)
        .fontDesign(settings.fontStyle.design)
        // The album tint used to be worked out only while Now Playing was on
        // screen, so the mini player kept a stale colour and a theme switch
        // (light and dark use different brightness rules) left it wrong.
        // RootView lives for the whole session, so it keeps the tint current.
        .onAppear { themes.updateArtworkAccent(from: player.currentArtwork) }
        .onChange(of: player.currentArtwork) { _, image in
            themes.updateArtworkAccent(from: image)
        }
        .onChange(of: settings.useAlbumArtColors) { _, _ in
            themes.refreshArtworkTint()
        }
        .onChange(of: player.errorMessage) { _, message in
            // While the full player is up it shows the alert itself; an alert
            // raised from behind a full-screen cover never appears.
            showErrorAlert = message != nil && !showFullPlayer
        }
        .alert("Playback problem", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { player.dismissError() }
        } message: {
            Text(player.errorMessage ?? "")
        }
        .sheet(isPresented: $showDuplicateReview) {
            DuplicateReviewView().themedSheet(themes)
        }
        .onChange(of: library.duplicateQuestions.isEmpty) { _, _ in askAboutDuplicates() }
        .onChange(of: library.isScanning) { _, _ in askAboutDuplicates() }
        .onChange(of: showFullPlayer) { _, _ in askAboutDuplicates() }
    }

    /// Opens the "are these the same song?" sheet when Sonora has found
    /// pairs it is not sure about — but not over the full player or in the
    /// middle of a scan, where more pairs may still turn up.
    private func askAboutDuplicates() {
        guard !askedAboutDuplicates, !showDuplicateReview,
              !library.duplicateQuestions.isEmpty,
              !showFullPlayer, !library.isScanning else { return }
        askedAboutDuplicates = true
        showDuplicateReview = true
    }
}

/// The queue tab reuses the sheet content without its own navigation chrome.
private struct QueueContentView: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        Group {
            if player.queue.isEmpty {
                EmptyStateView(symbol: "list.bullet",
                               title: "Queue is empty",
                               message: "Play an album, folder or playlist and it will show up here.")
            } else {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { index, id in
                        if let track = library.track(id: id) {
                            TrackRow(track: track,
                                     isCurrent: index == player.currentIndex,
                                     isPlaying: index == player.currentIndex && player.isPlaying)
                                .contentShape(Rectangle())
                                .onTapGesture { player.jump(to: index); Haptics.tap() }
                                .listRowBackground(index == player.currentIndex
                                                   ? themes.accent.opacity(0.14) : Color.clear)
                                .listRowSeparatorTint(themes.theme.separator)
                        }
                    }
                    .onDelete { player.removeFromQueue(at: $0) }
                    .onMove { player.moveInQueue(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .themedList(themes.theme)
            }
        }
        .background(themes.theme.background.ignoresSafeArea())
        .themedNavBar(themes.theme)
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton().tint(themes.accent) }
        }
        .miniPlayerClearance()
    }
}
