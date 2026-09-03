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
                    .tabItem { Label("Library", systemImage: "music.note.house") }
                    .tag(0)

                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(1)

                NavigationStack { QueueContentView() }
                    .tabItem { Label("Queue", systemImage: "list.bullet") }
                    .tag(2)

                SettingsView()
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.currentTrack?.id)
        .fullScreenCover(isPresented: $showFullPlayer) {
            NowPlayingView()
        }
        .preferredColorScheme(themes.colorScheme)
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
                        }
                    }
                    .onDelete { player.removeFromQueue(at: $0) }
                    .onMove { player.moveInQueue(from: $0, to: $1) }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton().tint(themes.accent) }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 60) }
    }
}
