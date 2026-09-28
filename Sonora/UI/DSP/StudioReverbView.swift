//
//  StudioReverbView.swift
//  Sonora
//
//  Controls for the Studio reverb engine (HallReverbUnit): presets, a
//  static picture of the decay envelope, and the full parameter set.
//
//  Everything here is drawn from the current settings only — no timers,
//  no animations — so the screen costs nothing while it sits open.
//

import SwiftUI

struct StudioReverbView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager

    /// Values the per-slider reset buttons return to.
    private static let defaults = AppSettings.StudioReverbPreset.chamber

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ReverbEnvelopeView(preDelayMS: settings.studioPreDelayMS,
                               decay: settings.studioDecay,
                               early: settings.studioEarly,
                               bassDecay: settings.studioBassDecay,
                               trebleDecay: settings.studioTrebleDecay,
                               accent: themes.accent,
                               secondary: themes.theme.textSecondary,
                               fill: themes.theme.surfaceElevated)
                .frame(height: 110)

            presetGrid

            section("Space") {
                LabeledSlider(title: "Vocal clarity", value: $settings.reverbClarity, range: 0...1,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              onReset: { settings.reverbClarity = 0.6 })
                Text("Turns the reverb down while someone is singing, so lyrics stay clear.")
                    .font(.system(size: 11))
                    .foregroundStyle(themes.theme.textSecondary)
                LabeledSlider(title: "Mix", value: bind(\.studioMix), range: 0...1,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              onReset: { reset(\.studioMix, to: Self.defaults.mix) })
                LogSlider(title: "Decay", value: bind(\.studioDecay), range: 0.2...20,
                          format: { StudioReverbView.seconds($0) },
                          onReset: { reset(\.studioDecay, to: Self.defaults.decay) })
                LabeledSlider(title: "Size", value: bind(\.studioSize), range: 0...1,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              onReset: { reset(\.studioSize, to: Self.defaults.size) })
                LabeledSlider(title: "Pre-delay", value: bind(\.studioPreDelayMS), range: 0...250,
                              format: { String(format: "%.0f ms", $0) },
                              onReset: { reset(\.studioPreDelayMS, to: Self.defaults.preDelayMS) })
            }

            section("Tone") {
                LabeledSlider(title: "Bass decay", value: bind(\.studioBassDecay), range: 0.5...2,
                              format: { String(format: "%.2f×", $0) },
                              onReset: { reset(\.studioBassDecay, to: Self.defaults.bassDecay) })
                LabeledSlider(title: "Treble decay", value: bind(\.studioTrebleDecay), range: 0.1...1,
                              format: { String(format: "%.2f×", $0) },
                              onReset: { reset(\.studioTrebleDecay, to: Self.defaults.trebleDecay) })
                LogSlider(title: "Low cut", value: bind(\.studioLowCut), range: 20...600,
                          format: { String(format: "%.0f Hz", $0) },
                          onReset: { reset(\.studioLowCut, to: Self.defaults.lowCut) })
                LogSlider(title: "High cut", value: bind(\.studioHighCut), range: 1000...20000,
                          format: { String(format: "%.1f kHz", $0 / 1000) },
                          onReset: { reset(\.studioHighCut, to: Self.defaults.highCut) })
            }

            section("Character") {
                LabeledSlider(title: "Diffusion", value: bind(\.studioDiffusion), range: 0...1,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              onReset: { reset(\.studioDiffusion, to: Self.defaults.diffusion) })
                LabeledSlider(title: "Modulation", value: bind(\.studioModulation), range: 0...1,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              onReset: { reset(\.studioModulation, to: Self.defaults.modulation) })
                LabeledSlider(title: "Early reflections", value: bind(\.studioEarly), range: 0...1,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              onReset: { reset(\.studioEarly, to: Self.defaults.early) })
                LabeledSlider(title: "Width", value: bind(\.studioWidth), range: 0...1,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              onReset: { reset(\.studioWidth, to: Self.defaults.width) })
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Room")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themes.theme.textPrimary)
                Text(settings.studioPresetName)
                    .font(.system(size: 12))
                    .foregroundStyle(themes.theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Button {
                    settings.studioFreeze.toggle()
                    Haptics.tap()
                } label: {
                    Label("Freeze", systemImage: "snowflake")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(settings.studioFreeze ? themes.accent : themes.theme.surfaceElevated,
                                    in: Capsule())
                        .foregroundStyle(settings.studioFreeze ? Color.white : themes.theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(settings.studioFreeze ? "On" : "Off"))

                Text("Holds the current tail")
                    .font(.system(size: 10))
                    .foregroundStyle(themes.theme.textSecondary)
            }
        }
    }

    // MARK: Presets

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(AppSettings.StudioReverbPreset.all) { preset in
                let selected = settings.studioPresetName == preset.name
                Button {
                    settings.apply(studioPreset: preset)
                    settings.reverbEnabled = true
                    Haptics.select()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .frame(height: 20)
                        Text(preset.name)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(String(format: "%.1f s", preset.decay))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(selected ? Color.white.opacity(0.8) : themes.theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
                    .background(selected ? themes.accent : themes.theme.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(selected ? Color.white : themes.theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(themes.theme.textSecondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themes.theme.surfaceElevated.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Moving a control by hand means the values are no longer the preset's.
    private func markCustom() {
        if settings.studioPresetName != "Custom" { settings.studioPresetName = "Custom" }
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<AppSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] },
                set: {
                    settings[keyPath: keyPath] = $0
                    markCustom()
                })
    }

    private func reset(_ keyPath: ReferenceWritableKeyPath<AppSettings, Double>, to value: Double) {
        settings[keyPath: keyPath] = value
        markCustom()
    }

    static func seconds(_ v: Double) -> String {
        if v < 1 { return String(format: "%.0f ms", v * 1000) }
        return String(format: v < 10 ? "%.2f s" : "%.1f s", v)
    }
}

// MARK: - Logarithmic slider

/// A LabeledSlider whose track is logarithmic, so the short end of a wide
/// range (small rooms, low cut-offs) gets as much travel as the long end.
private struct LogSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var onReset: (() -> Void)? = nil

    var body: some View {
        let lo = range.lowerBound
        let hi = range.upperBound
        let binding = $value
        let position = Binding<Double>(
            get: { LogSlider.position(of: binding.wrappedValue, lo: lo, hi: hi) },
            set: { binding.wrappedValue = LogSlider.mapped(at: $0, lo: lo, hi: hi) })
        let formatter = format
        LabeledSlider(title: title, value: position, range: 0...1,
                      format: { formatter(LogSlider.mapped(at: $0, lo: lo, hi: hi)) },
                      onReset: onReset)
    }

    /// Slider position t ∈ 0...1 → value lo·(hi/lo)^t.
    static func mapped(at t: Double, lo: Double, hi: Double) -> Double {
        let clamped = min(1, max(0, t))
        return lo * pow(hi / lo, clamped)
    }

    /// Value → slider position, clamped to the track.
    static func position(of v: Double, lo: Double, hi: Double) -> Double {
        guard v > 0, lo > 0, hi > lo else { return 0 }
        return min(1, max(0, log(v / lo) / log(hi / lo)))
    }
}

// MARK: - Envelope

/// Static sketch of the reverb's energy over time: the dry hit, the
/// pre-delay gap, early reflections, then the exponential tail (60 dB down
/// at the decay time), with fainter bass and treble tails for comparison.
struct ReverbEnvelopeView: View {
    let preDelayMS: Double
    let decay: Double
    let early: Double
    let bassDecay: Double
    let trebleDecay: Double
    let accent: Color
    let secondary: Color
    let fill: Color

    var body: some View {
        Canvas { context, size in
            render(&context, size: size)
        }
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Reverb decay envelope")
        .accessibilityValue(StudioReverbView.seconds(decay) + " decay")
    }

    private func render(_ ctx: inout GraphicsContext, size: CGSize) {
        let left: CGFloat = 8
        let right: CGFloat = 8
        let top: CGFloat = 16
        let bottom: CGFloat = 16
        let w = max(1, size.width - left - right)
        let h = max(1, size.height - top - bottom)
        let baseY = top + h

        let rt60 = max(0.05, decay)
        let pre = max(0, preDelayMS) / 1000
        let tMax = max(min(rt60 * 1.2, 10), pre + 0.05)
        let peak = 0.8
        let rise = max(0.003, min(0.03, rt60 * 0.03))

        func xPos(_ t: Double) -> CGFloat {
            left + CGFloat(t / tMax) * w
        }
        func yPos(_ a: Double) -> CGFloat {
            baseY - CGFloat(max(0, min(1, a))) * h
        }
        func envelope(_ t: Double, _ rt: Double) -> Double {
            guard t >= pre else { return 0 }
            let dt = t - pre
            return peak * (1 - exp(-dt / rise)) * pow(10, -3 * dt / max(0.05, rt))
        }
        func curve(_ rt: Double) -> Path {
            var p = Path()
            let steps = 120
            p.move(to: CGPoint(x: xPos(pre), y: baseY))
            for i in 0...steps {
                let t = pre + (tMax - pre) * Double(i) / Double(steps)
                p.addLine(to: CGPoint(x: xPos(t), y: yPos(envelope(t, rt))))
            }
            return p
        }
        func label(_ s: String) -> Text {
            Text(s)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(secondary)
        }
        func markPoint(_ rt: Double, level: Double) -> CGPoint {
            let dt = -log10(level / peak) / 3 * max(0.05, rt)
            let t = min(pre + dt, tMax * 0.85)
            return CGPoint(x: xPos(t), y: yPos(envelope(t, rt)))
        }

        // Baseline.
        var base = Path()
        base.move(to: CGPoint(x: left, y: baseY))
        base.addLine(to: CGPoint(x: left + w, y: baseY))
        ctx.stroke(base, with: .color(secondary.opacity(0.35)), lineWidth: 1)

        // Dry signal at t = 0.
        var direct = Path()
        direct.move(to: CGPoint(x: left + 1, y: baseY))
        direct.addLine(to: CGPoint(x: left + 1, y: yPos(1)))
        ctx.stroke(direct, with: .color(secondary.opacity(0.8)), lineWidth: 2)

        // Pre-delay gap, labelled when there is room for it.
        let gap = xPos(pre) - xPos(0)
        if gap > 44 {
            ctx.draw(label(String(format: "%.0f ms", preDelayMS)),
                     at: CGPoint(x: xPos(0) + gap / 2, y: baseY - 4),
                     anchor: .bottom)
        }

        // Main tail.
        let tail = curve(rt60)
        var area = tail
        area.addLine(to: CGPoint(x: xPos(tMax), y: baseY))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(Gradient(colors: [accent.opacity(0.35), accent.opacity(0.04)]),
                                             startPoint: CGPoint(x: 0, y: top),
                                             endPoint: CGPoint(x: 0, y: baseY)))
        ctx.stroke(tail, with: .color(accent), lineWidth: 1.5)

        // Bass and treble tails.
        let bassRT = rt60 * bassDecay
        let trebleRT = rt60 * trebleDecay
        ctx.stroke(curve(bassRT), with: .color(secondary.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        ctx.stroke(curve(trebleRT), with: .color(secondary.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1, dash: [1, 2]))

        // Early reflections.
        if early > 0.01 {
            let span = max(min(0.08, rt60 * 0.25), tMax * 0.05)
            let pattern: [Double] = [1.0, 0.62, 0.84, 0.5, 0.7, 0.42]
            for (i, k) in pattern.enumerated() {
                let t = min(tMax, pre + span * (Double(i) + 0.5) / Double(pattern.count))
                let a = min(1, early) * 0.95 * k
                var spike = Path()
                spike.move(to: CGPoint(x: xPos(t), y: baseY))
                spike.addLine(to: CGPoint(x: xPos(t), y: yPos(a)))
                ctx.stroke(spike, with: .color(accent.opacity(0.9)), lineWidth: 1.5)
            }
        }

        // Labels.
        let bassPoint = markPoint(bassRT, level: 0.3)
        ctx.draw(label("Bass"), at: CGPoint(x: bassPoint.x + 3, y: bassPoint.y - 2), anchor: .bottomLeading)
        let treblePoint = markPoint(trebleRT, level: 0.3)
        ctx.draw(label("Treble"), at: CGPoint(x: treblePoint.x + 3, y: treblePoint.y + 3), anchor: .topLeading)

        ctx.draw(label("0"), at: CGPoint(x: left, y: baseY + 3), anchor: .topLeading)
        ctx.draw(label(StudioReverbView.seconds(tMax)), at: CGPoint(x: left + w, y: baseY + 3), anchor: .topTrailing)
        ctx.draw(label("RT60 " + StudioReverbView.seconds(rt60)), at: CGPoint(x: left + w, y: 3), anchor: .topTrailing)
    }
}
