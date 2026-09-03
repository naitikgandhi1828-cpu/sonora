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
    @State private var waveform: WaveformData?
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    private var fraction: Double {
        if isScrubbing { return scrubFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .leading) {
                if let waveform, !waveform.peaks.isEmpty {
                    Canvas { context, size in
                        draw(waveform: waveform, in: context, size: size, progress: fraction)
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

                // Playhead
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
                        onScrubChanged(scrubFraction * duration)
                    }
                    .onEnded { value in
                        let f = min(1, max(0, value.location.x / max(1, width)))
                        isScrubbing = false
                        onScrubEnded(f * duration)
                    }
            )
        }
        .task(id: trackID) { await loadWaveform() }
    }

    private func draw(waveform: WaveformData, in context: GraphicsContext, size: CGSize, progress: Double) {
        let count = waveform.peaks.count
        guard count > 0 else { return }
        let barWidth = max(1.0, size.width / Double(count) * 0.62)
        let spacing = size.width / Double(count)
        let mid = size.height / 2
        let playedX = size.width * progress

        let playedColor = themes.accent
        let pendingColor = themes.theme.textSecondary.opacity(0.30)

        for i in 0..<count {
            let x = Double(i) * spacing
            let peak = Double(waveform.peaks[i])
            let rms = Double(waveform.rms[i])
            let h = max(2.0, peak * (size.height - 4))
            let innerH = max(1.5, rms * (size.height - 4))

            let rect = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
            let innerRect = CGRect(x: x, y: mid - innerH / 2, width: barWidth, height: innerH)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            let innerPath = Path(roundedRect: innerRect, cornerRadius: barWidth / 2)

            let color = x + barWidth <= playedX ? playedColor : pendingColor
            context.fill(path, with: .color(color.opacity(0.55)))
            context.fill(innerPath, with: .color(color))
        }
    }

    private func loadWaveform() async {
        waveform = nil
        guard let trackID, let url else { return }
        let data = await WaveformAnalyzer.shared.waveform(for: trackID,
                                                          url: url,
                                                          startTime: startTime,
                                                          endTime: endTime,
                                                          buckets: 300)
        await MainActor.run { withAnimation(.easeOut(duration: 0.35)) { self.waveform = data } }
    }
}

// MARK: - Plain seek bar (used in the mini player)

struct SlimProgressBar: View {
    let fraction: Double
    var height: CGFloat = 2

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(themes.theme.textSecondary.opacity(0.2))
                Rectangle().fill(themes.accent)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Spectrum visualizer

struct SpectrumView: View {
    let levels: [Float]
    var barCount: Int = 24

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        GeometryReader { geo in
            let spacing = geo.size.width / Double(max(1, barCount)) * 0.3
            let barWidth = (geo.size.width - spacing * Double(barCount - 1)) / Double(barCount)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let level = i < levels.count ? Double(levels[i]) : 0
                    let shaped = pow(level, 0.6)
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(themes.accent.opacity(0.35 + 0.65 * shaped))
                        .frame(width: barWidth,
                               height: max(2, geo.size.height * shaped))
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
