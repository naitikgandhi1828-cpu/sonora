//
//  RootView.swift
//  Sonora
//
//  Tab shell with the persistent mini player docked above the tab bar.
//

import SwiftUI

struct RootView: View {

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager

    @State private var selectedTab = 0
    @State private var showFullPlayer = false
    @State private var showErrorAlert = false

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

            if player.currentTrack != nil {
                MiniPlayerView(showFullPlayer: $showFullPlayer)
                    .padding(.bottom, 49)   // sits above the tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(themes.theme.background.ignoresSafeArea())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.currentTrack?.id)
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
            showErrorAlert = message != nil
        }
        .alert("Playback problem", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
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
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 60) }
    }
}
