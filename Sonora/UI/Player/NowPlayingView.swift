//
//  NowPlayingView.swift
//  Sonora
//
//  The full-screen player.
//

import SwiftUI

struct NowPlayingView: View {

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    @State private var showDSP = false
    @State private var showSleep = false
    @State private var showInfo = false

    private var track: Track? { player.currentTrack }

    var body: some View {
        ZStack {
            background
            content
        }
        .preferredColorScheme(themes.colorScheme)
        .sheet(isPresented: $showQueue) { QueueView().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showDSP) { DSPHomeView().presentationDetents([.large]) }
        .sheet(isPresented: $showSleep) { SleepTimerView().presentationDetents([.medium]) }
        .sheet(isPresented: $showInfo) {
            if let track { TrackInfoView(track: track).presentationDetents([.medium, .large]) }
        }
        .onChange(of: player.currentArtwork) { _, image in
            themes.updateArtworkAccent(from: image)
        }
        .onAppear { themes.updateArtworkAccent(from: player.currentArtwork) }
    }

    // MARK: Background

    @ViewBuilder
    private var background: some View {
        ZStack {
            themes.theme.background
            if settings.blurredArtBackground, let art = player.currentArtwork {
                Image(uiImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 70, opaque: true)
                    .overlay(themes.theme.background.opacity(themes.theme.isDark ? 0.62 : 0.78))
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            LinearGradient(colors: [.clear, themes.theme.background.opacity(0.85)],
                           startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.4), value: player.currentArtwork)
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 8)
            artwork
            Spacer(minLength: 8)
            titleBlock
            seekSection
            transportRow
            secondaryRow
            Spacer(minLength: 4)
            bottomBar
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(themes.theme.surface.opacity(0.7), in: Circle())
            }
            Spacer()
            VStack(spacing: 1) {
                Text(player.queueSourceName.isEmpty ? "Now Playing" : player.queueSourceName.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(themes.theme.textSecondary)
                if !player.queue.isEmpty {
                    Text("\(player.currentIndex + 1) of \(player.queue.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(themes.theme.textSecondary.opacity(0.75))
                }
            }
            Spacer()
            Menu {
                Button { showInfo = true } label: { Label("Track Info", systemImage: "info.circle") }
                Button { showQueue = true } label: { Label("Play Queue", systemImage: "list.bullet") }
                Button { showDSP = true } label: { Label("Equalizer & DSP", systemImage: "slider.horizontal.3") }
                Button { showSleep = true } label: { Label("Sleep Timer", systemImage: "moon.zzz") }
                Divider()
                if let track {
                    Menu("Rate") {
                        ForEach((0...5).reversed(), id: \.self) { r in
                            Button {
                                library.setRating(r, for: track.id)
                                Haptics.select()
                            } label: {
                                Label(r == 0 ? "No rating" : String(repeating: "★", count: r),
                                      systemImage: track.rating == r ? "checkmark" : "")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(themes.theme.surface.opacity(0.7), in: Circle())
            }
        }
        .foregroundStyle(themes.theme.textPrimary)
        .padding(.top, 6)
    }

    private var artwork: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ArtworkView(key: track?.artworkKey,
                            size: side,
                            cornerRadius: 18,
                            useThumbnail: false,
                            fallbackSymbol: "music.quarternote.3")
                    .shadow(color: .black.opacity(0.45), radius: 26, y: 14)

                if settings.showVisualizer && player.isPlaying {
                    SpectrumView(levels: player.meterLevels)
                        .frame(height: side * 0.16)
                        .padding(.horizontal, side * 0.08)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, side * 0.06)
                        .opacity(0.85)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxHeight: 380)
        .onTapGesture(count: 2) { player.togglePlayPause(); Haptics.tap() }
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(track?.displayTitle ?? "Nothing playing")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(themes.theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)

            Text(track.map { "\($0.displayArtist) — \($0.displayAlbum)" } ?? "Pick something from your library")
                .font(.system(size: 14))
                .foregroundStyle(themes.theme.textSecondary)
                .lineLimit(1)

            if let track {
                HStack(spacing: 6) {
                    Text(track.qualityBadge)
                    if track.isCueTrack {
                        Text("CUE")
                    }
                    Image(systemName: AudioSessionManager.shared.routeSymbol)
                }
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(themes.theme.textSecondary.opacity(0.8))
                .padding(.top, 1)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var seekSection: some View {
        VStack(spacing: 4) {
            Group {
                if settings.showWaveformSeekBar {
                    WaveformSeekBar(trackID: track?.id,
                                    url: track.flatMap { library.url(for: $0) },
                                    startTime: track?.cueStart ?? 0,
                                    endTime: track?.cueEnd,
                                    position: player.position,
                                    duration: max(player.duration, 0.01),
                                    onScrubBegan: { player.beginScrub() },
                                    onScrubChanged: { player.scrubPreview($0) },
                                    onScrubEnded: { player.endScrub(at: $0) })
                        .frame(height: 52)
                } else {
                    Slider(value: Binding(
                        get: { min(player.position, max(player.duration, 0.01)) },
                        set: { player.scrubPreview($0) }
                    ), in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
                        if editing { player.beginScrub() } else { player.endScrub(at: player.position) }
                    })
                    .tint(themes.accent)
                    .frame(height: 52)
                }
            }

            HStack {
                Text(player.position.timecode)
                Spacer()
                Text("-" + max(0, player.duration - player.position).timecode)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(themes.theme.textSecondary)
        }
    }

    private var transportRow: some View {
        HStack {
            Button { player.cycleShuffle(); Haptics.select() } label: {
                Image(systemName: settings.shuffleMode == .albums ? "shuffle.circle" : "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(settings.shuffleMode == .off
                                     ? themes.theme.textSecondary : themes.accent)
            }
            Spacer()
            Button { player.previous(); Haptics.tap() } label: {
                Image(systemName: "backward.fill").font(.system(size: 26))
            }
            Spacer()
            Button { player.togglePlayPause(); Haptics.tap() } label: {
                ZStack {
                    Circle().fill(themes.accent).frame(width: 68, height: 68)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(.white)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
                .shadow(color: themes.accent.opacity(0.4), radius: 14, y: 6)
            }
            Spacer()
            Button { player.next(userInitiated: true); Haptics.tap() } label: {
                Image(systemName: "forward.fill").font(.system(size: 26))
            }
            Spacer()
            Button { player.cycleRepeat(); Haptics.select() } label: {
                Image(systemName: settings.repeatMode.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(settings.repeatMode == .off
                                     ? themes.theme.textSecondary : themes.accent)
            }
        }
        .foregroundStyle(themes.theme.textPrimary)
        .padding(.vertical, 14)
    }

    private var secondaryRow: some View {
        HStack(spacing: 26) {
            Button { player.skipBackward(); Haptics.tap() } label: {
                Label("\(Int(settings.seekStepSeconds))", systemImage: "gobackward")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18))
            }
            Button { showDSP = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18))
                    .foregroundStyle(player.dsp.isActive ? themes.accent : themes.theme.textSecondary)
            }
            Button { showSleep = true } label: {
                Image(systemName: player.sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 18))
                    .foregroundStyle(player.sleepTimer.isActive ? themes.accent : themes.theme.textSecondary)
            }
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet").font(.system(size: 18))
            }
            Button { player.skipForward(); Haptics.tap() } label: {
                Image(systemName: "goforward").font(.system(size: 18))
            }
        }
        .foregroundStyle(themes.theme.textSecondary)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if player.sleepTimer.isActive {
                Label(player.sleepTimer.formattedRemaining, systemImage: "moon.zzz.fill")
            }
            if abs(settings.playbackRate - 1) > 0.01 {
                Label(String(format: "%.2fx", settings.playbackRate), systemImage: "speedometer")
            }
            if settings.eqEnabled {
                Label(settings.selectedPresetName, systemImage: "waveform")
            }
            if settings.reverbEnabled {
                Label(settings.reverbRoom.label, systemImage: "square.stack.3d.down.right")
            }
            if settings.replayGainMode != .off {
                Label("RG", systemImage: "speaker.wave.2.circle")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(themes.theme.textSecondary.opacity(0.85))
        .frame(height: 16)
    }
}

// MARK: - Track info

struct TrackInfoView: View {
    let track: Track
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ArtworkView(key: track.artworkKey, size: 84, cornerRadius: 10, useThumbnail: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.displayTitle).font(.headline).lineLimit(2)
                            Text(track.displayArtist).font(.subheadline).foregroundStyle(.secondary)
                            Text(track.displayAlbum).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Tags") {
                    row("Album Artist", track.effectiveAlbumArtist)
                    row("Genre", track.genre.isEmpty ? "—" : track.genre)
                    row("Composer", track.composer.isEmpty ? "—" : track.composer)
                    row("Year", track.year.map(String.init) ?? "—")
                    row("Track", track.trackNumber.map { n in
                        track.trackTotal.map { "\(n) of \($0)" } ?? "\(n)"
                    } ?? "—")
                    row("Disc", track.discNumber.map(String.init) ?? "—")
                    if !track.comment.isEmpty { row("Comment", track.comment) }
                }
                Section("Audio") {
                    row("Format", track.fileExtension.uppercased())
                    row("Codec", track.codec.isEmpty ? "—" : track.codec)
                    row("Sample Rate", track.sampleRate > 0 ? "\(Int(track.sampleRate)) Hz" : "—")
                    row("Bit Depth", track.bitDepth.map { "\($0)-bit" } ?? "—")
                    row("Channels", "\(track.channelCount)")
                    row("Bitrate", track.bitrate.map { "\($0) kbps" } ?? "—")
                    row("Duration", track.duration.timecode)
                    if track.isCueTrack {
                        row("Cue Range",
                            "\((track.cueStart ?? 0).timecode) – \((track.cueEnd ?? 0).timecode)")
                    }
                }
                Section("Replay Gain") {
                    row("Track Gain", track.replayGainTrack.map { String(format: "%.2f dB", $0) } ?? "Not measured")
                    row("Album Gain", track.replayGainAlbum.map { String(format: "%.2f dB", $0) } ?? "Not measured")
                    row("Peak", track.peakTrack.map { String(format: "%.4f", $0) } ?? "—")
                }
                Section("Library") {
                    row("Plays", "\(track.playCount)")
                    row("Rating", track.rating > 0 ? String(repeating: "★", count: track.rating) : "—")
                    row("Added", track.dateAdded.formatted(date: .abbreviated, time: .shortened))
                    row("Size", track.fileSize.byteSize)
                    row("Path", track.relativePath)
                }
            }
            .navigationTitle("Track Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 14))
    }
}
