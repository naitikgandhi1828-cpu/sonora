//
//  NowPlayingView.swift
//  Sonora
//
//  The full-screen player.
//

import SwiftUI
import CoreImage
import UIKit

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
    @State private var showLyrics = false
    @State private var editTarget: TagEditTarget?

    private var track: Track? { player.currentTrack }

    private var hasLyrics: Bool {
        !(track?.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
        .sheet(item: $editTarget) { target in
            TagEditorView(trackIDs: target.trackIDs)
        }
        .sheet(isPresented: $showLyrics) {
            LyricsView().presentationDetents([.medium, .large])
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

            // A wash of the cover's own colour under the blur. The blur alone
            // went grey on anything busy; the tint is what carries the album's
            // character down the whole screen.
            if settings.blurredArtBackground, let art = player.currentArtwork {
                // The GeometryReader is what keeps this honest. A `.fill` image
                // with no frame reports whatever size the aspect ratio demands,
                // and a wide cover therefore made this ZStack wider than the
                // screen - which pushed the transport controls off the sides.
                // Square art happened to look fine, which is why only *some*
                // albums broke the layout.
                GeometryReader { geo in
                    // Pre-blurred once per track on a background thread. A
                    // live 80pt SwiftUI blur is re-rendered by the GPU every
                    // time anything on this screen changes.
                    ArtBackdrop(artKey: player.currentTrack?.artworkKey, art: art)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay(themes.theme.background.opacity(themes.theme.isDark ? 0.58 : 0.74))
                        .clipped()
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            LinearGradient(colors: [themes.accent.opacity(themes.theme.isDark ? 0.22 : 0.14),
                                    .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            LinearGradient(colors: [.clear, themes.theme.background.opacity(0.9)],
                           startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.45), value: player.currentArtwork)
        .animation(.easeInOut(duration: 0.45), value: themes.accent)
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
                if let track {
                    Button {
                        editTarget = TagEditTarget(trackIDs: [track.id])
                    } label: { Label("Edit Tags", systemImage: "tag") }
                }
                if hasLyrics {
                    Button { showLyrics = true } label: { Label("Lyrics", systemImage: "quote.bubble") }
                }
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
                ArtworkPager(previousKey: player.artworkKey(offsetBy: -1),
                             currentKey: track?.artworkKey,
                             nextKey: player.artworkKey(offsetBy: 1),
                             side: side,
                             hasPrevious: player.canGoPrevious,
                             hasNext: player.canGoNext,
                             onPrevious: { player.previous(allowRestart: false) },
                             onNext: { player.next(userInitiated: true) },
                             onSwipeDown: { showQueue = true })

                if settings.visualizerAllowed && player.isPlaying {
                    SpectrumView(meters: player.meters)
                        .frame(height: side * 0.16)
                        .padding(.horizontal, side * 0.08)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, side * 0.06)
                        .opacity(0.85)
                        .allowsHitTesting(false)
                        .onAppear { player.setVisualizerVisible(true) }
                        .onDisappear { player.setVisualizerVisible(false) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxHeight: 380)
        .onTapGesture(count: 2) { player.togglePlayPause(); Haptics.tap() }
    }

    private var titleBlock: some View {
        titleContent
            // Crossfade the text on a track change so it settles with the
            // artwork instead of snapping a beat ahead of it.
            .id(track?.id)
            .transition(.opacity.combined(with: .offset(y: 6)))
            .animation(.easeInOut(duration: 0.28), value: track?.id)
    }

    private var titleContent: some View {
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
        // Lives in its own view observing only the clock, so the playhead
        // ticking does not re-render the rest of this screen.
        SeekSection(clock: player.clock, track: track)
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
        secondaryButtons
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(themes.theme.surface.opacity(0.55),
                        in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .stroke(themes.theme.separator.opacity(0.5), lineWidth: 0.5))
    }

    private var secondaryButtons: some View {
        HStack(spacing: 26) {
            Button { player.skipBackward(); Haptics.tap() } label: {
                // Formatted, not `Int(...)`: a corrupt stored value (NaN) would trap.
                Label(String(format: "%.0f", settings.seekStepSeconds), systemImage: "gobackward")
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
                Label(settings.activeReverbName, systemImage: "square.stack.3d.down.right")
            }
            if settings.spatialEnabled {
                Label("Spatial", systemImage: "airpodspro")
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

// MARK: - Swipeable artwork

/// Album art you can swipe through, one track per swipe.
///
/// The neighbouring covers are laid out either side of the current one and the
/// whole strip follows the finger, so a swipe reads as travelling through the
/// queue rather than as a button press that happens to change the song. They
/// stay invisible at rest and fade in as the drag opens a gap, which keeps the
/// screen calm when nobody is touching it.
///
/// The track only changes once the settle animation has finished. Changing it
/// on release instead would swap the picture out from under a strip that is
/// still moving, and the transition would tear.
private struct ArtworkPager: View {

    let previousKey: String?
    let currentKey: String?
    let nextKey: String?
    let side: CGFloat
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    /// Pulling the artwork down opens the queue.
    var onSwipeDown: () -> Void = {}

    @State private var dragX: CGFloat = 0
    /// Vertical follow-the-finger offset for the swipe-down-to-queue gesture.
    @State private var dragY: CGFloat = 0
    @State private var isSettling = false
    /// Locked on the first movement so a drag is either a track swipe or a
    /// queue pull, never a diagonal mix of both.
    @State private var axis: DragAxis = .undecided

    private enum DragAxis { case undecided, horizontal, vertical }

    private var gap: CGFloat { max(18, side * 0.08) }
    private var step: CGFloat { side + gap }

    /// Neighbours fade in with the drag rather than sitting there all the time.
    private var neighbourOpacity: Double {
        Double(min(1, abs(dragX) / (step * 0.5)))
    }

    private var centreOpacity: Double {
        1 - 0.3 * Double(min(1, abs(dragX) / step))
    }

    var body: some View {
        HStack(spacing: gap) {
            cover(previousKey).opacity(neighbourOpacity)
            cover(currentKey).opacity(centreOpacity)
            cover(nextKey).opacity(neighbourOpacity)
        }
        .offset(x: dragX)
        // The strip is three covers wide; this frame crops the view back to one
        // and centres it, so the neighbours sit just off screen at rest.
        .frame(width: side, height: side)
        // Swipe-down: the cover sinks and shrinks slightly under the finger.
        .scaleEffect(1 - min(0.12, dragY / 1600))
        .offset(y: dragY)
        .contentShape(Rectangle())
        .simultaneousGesture(drag)
    }

    private func cover(_ key: String?) -> some View {
        ArtworkView(key: key,
                    size: side,
                    cornerRadius: side * 0.055,
                    useThumbnail: false,
                    fallbackSymbol: "music.quarternote.3")
            .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard !isSettling else { return }
                if axis == .undecided {
                    axis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal : .vertical
                }
                if axis == .vertical {
                    // Only downward pulls do anything; follow the finger with
                    // a little resistance so it feels attached, not loose.
                    let down = max(0, value.translation.height)
                    dragY = down < 120 ? down * 0.75 : 90 + (down - 120) * 0.3
                    return
                }

                let raw = value.translation.width
                let atEnd = (raw < 0 && !hasNext) || (raw > 0 && !hasPrevious)
                // Rubber-band at the ends of the queue: it still moves, so the
                // gesture feels alive, but it clearly refuses to go anywhere.
                dragX = atEnd ? raw * 0.2 : raw
            }
            .onEnded { value in
                let endedAxis = axis
                axis = .undecided
                guard !isSettling else { return }

                if endedAxis == .vertical {
                    let pulled = value.translation.height > 80
                        || value.predictedEndTranslation.height > 220
                    if pulled {
                        Haptics.tap()
                        onSwipeDown()
                    }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { dragY = 0 }
                    return
                }

                let travelled = value.translation.width
                let flick = value.predictedEndTranslation.width
                let threshold = side * 0.26
                let goNext = hasNext && (travelled < -threshold || flick < -side)
                let goPrevious = hasPrevious && (travelled > threshold || flick > side)

                guard goNext || goPrevious else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dragX = 0 }
                    return
                }

                isSettling = true
                Haptics.tap()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    dragX = goNext ? -step : step
                } completion: {
                    // Snap back and change track in the same update, so the
                    // incoming cover simply becomes the centre one.
                    dragX = 0
                    isSettling = false
                    if goNext { onNext() } else { onPrevious() }
                }
            }
    }
}

// MARK: - Track info

struct TrackInfoView: View {
    let track: Track
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var editTarget: TagEditTarget?

    var body: some View {
        // Live copy, so edits made from the Edit Tags button show here at once.
        let track = library.track(id: self.track.id) ?? self.track

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
                    row("Sample Rate", track.sampleRate > 0 ? String(format: "%.0f Hz", track.sampleRate) : "—")
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        editTarget = TagEditTarget(trackIDs: [track.id])
                    } label: { Label("Edit Tags", systemImage: "tag") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editTarget) { target in
                TagEditorView(trackIDs: target.trackIDs)
            }
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

// MARK: - Seek section

private struct SeekSection: View {
    @ObservedObject var clock: PlaybackClock
    let track: Track?

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        let elapsed = player.elapsed(at: clock.position)
        let length = player.trackLength
        VStack(spacing: 4) {
            Group {
                if settings.showWaveformSeekBar {
                    WaveformSeekBar(trackID: track?.id,
                                    url: track.flatMap { library.url(for: $0) },
                                    // Analysis range and display range are the
                                    // same thing: the track's own extent. Left
                                    // nil for ordinary files so the analyser
                                    // reads to the end of the file rather than
                                    // to a duration that may not have arrived
                                    // from the engine yet.
                                    startTime: track?.cueStart ?? 0,
                                    endTime: track?.cueEnd,
                                    position: clock.position,
                                    duration: max(clock.duration, 0.01),
                                    onScrubBegan: { player.beginScrub() },
                                    onScrubChanged: { player.scrubPreview($0) },
                                    onScrubEnded: { player.endScrub(at: $0) })
                        .frame(height: 52)
                } else {
                    // The plain slider works in track time too, so both bars
                    // behave identically on cue-sheet tracks.
                    Slider(value: Binding(
                        get: { min(elapsed, max(length, 0.01)) },
                        set: { player.scrubPreview(player.trackStart + $0) }
                    ), in: 0...max(length, 0.01), onEditingChanged: { editing in
                        if editing { player.beginScrub() } else { player.endScrub(at: player.position) }
                    })
                    .tint(themes.accent)
                    .frame(height: 52)
                }
            }

            HStack {
                Text(elapsed.timecode)
                Spacer()
                Text("-" + max(0, length - elapsed).timecode)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(themes.theme.textSecondary)
        }
    }
}

// MARK: - Blurred backdrop

/// Shows a pre-blurred copy of the artwork, computed once per track.
private struct ArtBackdrop: View {
    let artKey: String?
    let art: UIImage

    @State private var blurred: UIImage?

    var body: some View {
        ZStack {
            if let blurred {
                Image(uiImage: blurred)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            }
        }
        .task(id: artKey) {
            let source = art
            let key = artKey
            let img = await Task.detached(priority: .utility) {
                Backdrop.blurred(from: source, cacheKey: key)
            }.value
            // A newer artKey cancelled this task while the blur ran; don't
            // let the stale image overwrite the newer track's backdrop.
            guard !Task.isCancelled else { return }
            blurred = img
        }
    }
}

enum Backdrop {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 8
        return c
    }()

    /// Shrinks the art to 64px and blurs that. Blurring a thumbnail is
    /// orders of magnitude cheaper than blurring full-size art, and the
    /// result is stretched full-screen anyway, so it looks the same.
    static func blurred(from image: UIImage, cacheKey: String?) -> UIImage? {
        if let cacheKey, let hit = cache.object(forKey: cacheKey as NSString) { return hit }

        let side: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        var result: UIImage = small
        if let input = CIImage(image: small) {
            let output = input.clampedToExtent()
                .applyingGaussianBlur(sigma: 5)
                .cropped(to: input.extent)
            if let cg = context.createCGImage(output, from: input.extent) {
                result = UIImage(cgImage: cg)
            }
        }
        if let cacheKey { cache.setObject(result, forKey: cacheKey as NSString) }
        return result
    }
}
