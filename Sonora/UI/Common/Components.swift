//
//  Components.swift
//  Sonora
//
//  Small reusable views.
//

import SwiftUI
import UIKit

// MARK: - Artwork

struct ArtworkView: View {
    let key: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8
    var useThumbnail: Bool = true
    var fallbackSymbol: String = "music.note"

    @EnvironmentObject private var themes: ThemeManager
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                themes.theme.surfaceElevated
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.34, weight: .light))
                    .foregroundStyle(themes.theme.textSecondary.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: key) { await loadImage() }
    }

    private func loadImage() async {
        guard let key else { image = nil; return }
        let wantsThumbnail = useThumbnail
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            wantsThumbnail ? ArtworkStore.shared.thumbnail(forKey: key)
                           : ArtworkStore.shared.image(forKey: key)
        }.value
        self.image = loaded
    }
}

// MARK: - Track row

struct TrackRow: View {
    let track: Track
    var showArtwork: Bool = true
    var showTrackNumber: Bool = false
    var isCurrent: Bool = false
    var isPlaying: Bool = false

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        HStack(spacing: 12) {
            if showTrackNumber {
                ZStack {
                    if isCurrent {
                        PlayingIndicator(animating: isPlaying, color: themes.accent)
                            .frame(width: 14, height: 14)
                    } else {
                        Text(track.trackNumber.map(String.init) ?? "–")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(themes.theme.textSecondary)
                    }
                }
                .frame(width: 26)
            } else if showArtwork {
                ArtworkView(key: track.artworkKey, size: 48, cornerRadius: 7)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.black.opacity(0.45))
                                .overlay(PlayingIndicator(animating: isPlaying, color: .white)
                                            .frame(width: 16, height: 16))
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? themes.accent : themes.theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(track.displayArtist)
                        .lineLimit(1)
                    if track.isHiRes {
                        Text("HI-RES")
                            .font(.system(size: 8, weight: .heavy))
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(themes.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(themes.accent)
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(themes.theme.textSecondary)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(track.duration.timecode)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(themes.theme.textSecondary)
                if track.rating > 0 {
                    HStack(spacing: 1) {
                        ForEach(0..<track.rating, id: \.self) { _ in
                            Image(systemName: "star.fill").font(.system(size: 7))
                        }
                    }
                    .foregroundStyle(themes.accent.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

// MARK: - Playing indicator

struct PlayingIndicator: View {
    var animating: Bool
    var color: Color
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { geo in
            let barCount = 3
            let spacing = geo.size.width * 0.16
            let width = (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = barHeight(index: i, max: geo.size.height)
                    RoundedRectangle(cornerRadius: width / 2)
                        .fill(color)
                        .frame(width: width, height: h)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear { if animating { start() } }
        .onChange(of: animating) { _, on in if on { start() } }
    }

    private func barHeight(index: Int, max height: CGFloat) -> CGFloat {
        guard animating else { return height * 0.35 }
        let offsets: [Double] = [0, 0.66, 1.33]
        let v = (sin(phase + offsets[index % offsets.count]) + 1) / 2
        return height * (0.25 + 0.75 * v)
    }

    private func start() {
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            phase = .pi * 2
        }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (() -> Void)?
    var actionLabel: String = "See All"

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(themes.theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(themes.theme.textSecondary)
                }
            }
            Spacer()
            if let action {
                Button(actionLabel, action: action)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themes.accent)
            }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(themes.accent.opacity(0.7))
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(themes.theme.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(themes.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(themes.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Labelled slider

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String
    var onReset: (() -> Void)?

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themes.theme.textPrimary)
                Spacer()
                Text(format(value))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(themes.accent)
                if let onReset {
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(themes.theme.textSecondary)
                }
            }
            if step > 0 {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
        .tint(themes.accent)
    }
}

// MARK: - Chip

struct Chip: View {
    let title: String
    var isSelected: Bool
    var action: () -> Void

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(isSelected ? themes.accent : themes.theme.surfaceElevated,
                            in: Capsule())
                .foregroundStyle(isSelected ? .white : themes.theme.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
