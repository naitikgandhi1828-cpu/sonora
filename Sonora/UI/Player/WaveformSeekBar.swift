//
//  WaveformSeekBar.swift
//  Sonora
//
//  A scrubbable seek bar that draws the track's peak envelope. Falls back
//  to a plain progress bar until the waveform has been analysed.
//

import SwiftUI

struct WaveformSeekBar: View {

    let trackID: UUID?
    let url: URL?
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let position: TimeInterval
    let duration: TimeInterval

    var onScrubBegan: () -> Void = {}
    var onScrubChanged: (TimeInterval) -> Void = { _ in }
    var onScrubEnded: (TimeInterval) -> Void = { _ in }

    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: AppSettings
    @State private var waveform: WaveformData?
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    /// The bar works in the track's own time, not the file's.
    ///
    /// `position` and `duration` are both file-absolute, which is the same
    /// thing for an ordinary file but not for a cue-sheet track: one starting
    /// ten minutes into a rip arrived here as position 600 of duration 640, so
    /// the playhead sat pinned near the right-hand end and the whole left of the
    /// bar mapped to times before the track had begun. Anchoring to
    /// [start, end] makes a cue track scrub across its full width, and leaves
    /// ordinary files exactly as they were (start 0, end = duration).
    private var lowerBound: TimeInterval { max(0, startTime) }
    private var upperBound: TimeInterval { max(lowerBound + 0.01, endTime ?? duration) }
    private var span: TimeInterval { upperBound - lowerBound }

    private func time(atFraction f: Double) -> TimeInterval {
        lowerBound + min(1, max(0, f)) * span
    }

    private var fraction: Double {
        if isScrubbing { return scrubFraction }
        let f = (position - lowerBound) / span
        // NaN would flow into `.frame(width:)` and `.offset`.
        guard f.isFinite else { return 0 }
        return min(1, max(0, f))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .leading) {
                if let waveform, !waveform.peaks.isEmpty {
                    // The bars are drawn once per track into two cached layers.
                    // Playback only moves a mask, so each tick costs almost
                    // nothing instead of redrawing 600 rounded paths.
                    WaveformLayer(waveform: waveform,
                                  color: themes.theme.textSecondary.opacity(0.30))
                        .equatable()
                    WaveformLayer(waveform: waveform, color: themes.accent)
                        .equatable()
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, width * fraction))
                        }
                } else {
                    Capsule()
                        .fill(themes.theme.textSecondary.opacity(0.22))
                        .frame(height: 5)
                        .frame(maxHeight: .infinity, alignment: .center)
                    Capsule()
                        .fill(themes.accent)
                        .frame(width: width * fraction, height: 5)
                        .frame(maxHeight: .infinity, alignment: .center)
                }

                // Playhead. Not animated between ticks: interpolating kept the
                // display redrawing at full frame rate for as long as music
                // played. At a few pixels per second the steps are invisible.
                Rectangle()
                    .fill(themes.theme.textPrimary)
                    .frame(width: 2, height: height)
                    .offset(x: max(0, min(width - 2, width * fraction)))
                    .opacity(isScrubbing ? 1 : 0.75)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            onScrubBegan()
                            Haptics.tap()
                        }
                        scrubFraction = min(1, max(0, value.location.x / max(1, width)))
                        onScrubChanged(time(atFraction: scrubFraction))
                    }
                    .onEnded { value in
                        let f = min(1, max(0, value.location.x / max(1, width)))
                        scrubFraction = f
                        isScrubbing = false
                        onScrubEnded(time(atFraction: f))
                    }
            )
        }
        // Re-run when the track changes or when heavy work becomes allowed
        // (battery saver switched off, or the phone was plugged in).
        .task(id: WaveformTaskKey(trackID: trackID,
                                  allowCompute: PowerState.mayRunHeavyWork(settings: settings))) {
            await loadWaveform()
        }
    }

    private func loadWaveform() async {
        waveform = nil
        guard let trackID, let url else { return }
        let data = await WaveformAnalyzer.shared.waveform(for: trackID,
                                                          url: url,
                                                          startTime: startTime,
                                                          endTime: endTime,
                                                          buckets: 300,
                                                          allowCompute: PowerState.mayRunHeavyWork(settings: settings))
        await MainActor.run { withAnimation(.easeOut(duration: 0.35)) { self.waveform = data } }
    }
}

private struct WaveformTaskKey: Equatable {
    let trackID: UUID?
    let allowCompute: Bool
}

// MARK: - Cached waveform layer

/// Draws the whole envelope in one colour. Equatable, so SwiftUI skips
/// redrawing it unless the waveform or colour actually changes.
private struct WaveformLayer: View, Equatable {
    let waveform: WaveformData
    let color: Color

    nonisolated static func == (lhs: WaveformLayer, rhs: WaveformLayer) -> Bool {
        lhs.color == rhs.color && lhs.waveform == rhs.waveform
    }

    var body: some View {
        Canvas { context, size in
            // `rms[i]` is read alongside `peaks[i]`; never trust the two arrays
            // to be the same length.
            let count = min(waveform.peaks.count, waveform.rms.count)
            guard count > 0, size.width > 0, size.height > 0 else { return }
            let spacing = size.width / Double(count)
            let barWidth = max(1.0, spacing * 0.62)
            let mid = size.height / 2
            var outer = Path()
            var inner = Path()
            for i in 0..<count {
                let x = Double(i) * spacing
                let h = max(2.0, Double(waveform.peaks[i]) * (size.height - 4))
                let innerH = max(1.5, Double(waveform.rms[i]) * (size.height - 4))
                outer.addRoundedRect(in: CGRect(x: x, y: mid - h / 2, width: barWidth, height: h),
                                     cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                inner.addRoundedRect(in: CGRect(x: x, y: mid - innerH / 2, width: barWidth, height: innerH),
                                     cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
            }
            // Two fills total instead of two per bar.
            context.fill(outer, with: .color(color.opacity(0.55)))
            context.fill(inner, with: .color(color))
        }
    }
}

// MARK: - Plain seek bar (used in the mini player)

struct SlimProgressBar: View {
    let fraction: Double
    var height: CGFloat = 2

    @EnvironmentObject private var themes: ThemeManager

    /// 0...1, with NaN (0/0 from an unknown length) treated as 0.
    private var clampedFraction: CGFloat {
        guard fraction.isFinite else { return 0 }
        return CGFloat(min(1, max(0, fraction)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(themes.theme.textSecondary.opacity(0.2))
                Rectangle().fill(themes.accent)
                    .frame(width: max(0, geo.size.width * clampedFraction))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Spectrum visualizer

/// Meter levels live on their own observable object rather than on
/// PlaybackController. Published there, every one of the ~15 updates a second
/// invalidated *all* views observing the player — the DSP and settings screens
/// included — which is what made the app feel sluggish everywhere. Only the
/// spectrum needs this data, so only the spectrum observes it.
final class MeterState: ObservableObject {
    @Published var levels: [Float] = Array(repeating: 0, count: 24)
}

/// One Canvas pass per update instead of 24 separately animated views.
/// Fed ~15 times a second, and only while this view is on screen.
struct SpectrumView: View {
    @ObservedObject var meters: MeterState

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        let accent = themes.accent
        let levels = meters.levels
        Canvas { context, size in
            let count = max(1, levels.count)
            let slot = size.width / CGFloat(count)
            let barWidth = slot * 0.7
            for i in 0..<levels.count {
                let level = Double(max(0, min(1, levels[i])))
                let shaped = pow(level, 0.6)
                let h = max(2, size.height * CGFloat(shaped))
                let rect = CGRect(x: CGFloat(i) * slot + (slot - barWidth) / 2,
                                  y: size.height - h,
                                  width: barWidth,
                                  height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(accent.opacity(0.35 + 0.65 * shaped)))
            }
        }
    }
}
