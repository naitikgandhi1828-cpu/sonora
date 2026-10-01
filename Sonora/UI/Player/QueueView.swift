//
//  QueueView.swift
//  Sonora
//

import SwiftUI

struct QueueView: View {

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            Group {
                if player.queue.isEmpty {
                    EmptyStateView(symbol: "list.bullet",
                                   title: "Queue is empty",
                                   message: "Play an album, folder or playlist to fill the queue.")
                } else {
                    ScrollViewReader { proxy in
                    List {
                        Section {
                            ForEach(Array(player.queue.enumerated()), id: \.offset) { index, id in
                                if let track = library.track(id: id) {
                                    TrackRow(track: track,
                                             isCurrent: index == player.currentIndex,
                                             isPlaying: index == player.currentIndex && player.isPlaying)
                                        .contentShape(Rectangle())
                                        .onTapGesture { player.jump(to: index); Haptics.tap() }
                                        .listRowBackground(index == player.currentIndex
                                                           ? themes.accent.opacity(0.14) : Color.clear)
                                        .id(index)
                                }
                            }
                            .onDelete { player.removeFromQueue(at: $0) }
                            .onMove { player.moveInQueue(from: $0, to: $1) }
                        } header: {
                            HStack {
                                Text(player.queueSourceName.isEmpty ? "Up Next" : player.queueSourceName)
                                Spacer()
                                QueueTimeLeft(clock: player.clock)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, $editMode)
                    .task {
                        // Open with the playing song in view. A short wait lets
                        // the sheet lay the list out first; scrolling before
                        // that is silently ignored.
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        scrollToCurrent(proxy, animated: false)
                    }
                    .onChange(of: player.currentIndex) { _, _ in
                        // Follow the music while the queue is open, but never
                        // yank the list away from someone reordering it.
                        guard editMode != .active else { return }
                        scrollToCurrent(proxy, animated: true)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if player.currentIndex >= 0 {
                            Button {
                                scrollToCurrent(proxy, animated: true)
                                Haptics.tap()
                            } label: {
                                Label("Now Playing", systemImage: "scope")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .tint(themes.accent)
                            .padding(16)
                        }
                    }
                    }
                }
            }
            .navigationTitle("Play Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(role: .destructive) { player.clearQueue(); dismiss() } label: {
                            Label("Clear Queue", systemImage: "trash")
                        }
                        Button {
                            let ids = player.queue
                            let name = "Queue \(Date().formatted(date: .abbreviated, time: .shortened))"
                            library.createPlaylist(named: name, trackIDs: ids)
                            Haptics.success()
                        } label: {
                            Label("Save as Playlist", systemImage: "text.badge.plus")
                        }
                        Divider()
                        Picker("Shuffle", selection: Binding(
                            get: { settings.shuffleMode },
                            set: { settings.shuffleMode = $0 })) {
                            ForEach(ShuffleMode.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Repeat", selection: Binding(
                            get: { settings.repeatMode },
                            set: { settings.repeatMode = $0 })) {
                            ForEach(RepeatMode.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode == .active ? "Done" : "Edit") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                }
            }
        }
    }
}

extension QueueView {
    fileprivate func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        let index = player.currentIndex
        guard index >= 0, index < player.queue.count else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}

// MARK: - Time left

/// The "time left" figure in the queue header. Observes the clock directly,
/// because `player.position` is not published and would never refresh here.
private struct QueueTimeLeft: View {
    @ObservedObject var clock: PlaybackClock

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        Text(totalRemaining)
    }

    private var totalRemaining: String {
        guard player.currentIndex >= 0 else { return "" }
        let remaining = player.queue.dropFirst(player.currentIndex)
            .compactMap { library.track(id: $0)?.duration }
            .reduce(0, +)
        return (remaining - clock.position).longFormat + " left"
    }
}
