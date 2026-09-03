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
                    List {
                        Section {
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
                        } header: {
                            HStack {
                                Text(player.queueSourceName.isEmpty ? "Up Next" : player.queueSourceName)
                                Spacer()
                                Text(totalRemaining)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, $editMode)
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

    private var totalRemaining: String {
        guard player.currentIndex >= 0 else { return "" }
        let remaining = player.queue.dropFirst(player.currentIndex)
            .compactMap { library.track(id: $0)?.duration }
            .reduce(0, +)
        return (remaining - player.position).longFormat + " left"
    }
}
