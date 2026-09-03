//
//  MiniPlayerView.swift
//  Sonora
//

import SwiftUI

struct MiniPlayerView: View {

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var themes: ThemeManager
    @Binding var showFullPlayer: Bool

    var body: some View {
        VStack(spacing: 0) {
            SlimProgressBar(fraction: player.duration > 0 ? player.position / player.duration : 0)

            HStack(spacing: 12) {
                ArtworkView(key: player.currentTrack?.artworkKey, size: 42, cornerRadius: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.displayTitle ?? "Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(themes.theme.textPrimary)
                        .lineLimit(1)
                    Text(player.currentTrack?.displayArtist ?? "—")
                        .font(.system(size: 12))
                        .foregroundStyle(themes.theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    player.togglePlayPause(); Haptics.tap()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19))
                        .frame(width: 40, height: 40)
                }
                Button {
                    player.next(userInitiated: true); Haptics.tap()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17))
                        .frame(width: 36, height: 40)
                }
            }
            .foregroundStyle(themes.theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(themes.theme.separator).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { showFullPlayer = true }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -30 { showFullPlayer = true }
                    else if value.translation.width < -60 { player.next(userInitiated: true) }
                    else if value.translation.width > 60 { player.previous() }
                }
        )
    }
}
