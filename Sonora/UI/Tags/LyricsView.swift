//
//  LyricsView.swift
//  Sonora
//
//  Shows the playing song's unsynchronised lyrics. Follows the player, so
//  the sheet updates when the next song starts.
//

import SwiftUI

struct LyricsView: View {

    @EnvironmentObject private var player: PlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let track = player.currentTrack
        let lyrics = (track?.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let track {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.displayTitle)
                                .font(.title3.weight(.bold))
                            Text(track.displayArtist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if lyrics.isEmpty {
                        Text("This song has no lyrics. You can add them with Edit Tags.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(lyrics)
                            .font(.system(size: 18, design: .serif))
                            .lineSpacing(7)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
