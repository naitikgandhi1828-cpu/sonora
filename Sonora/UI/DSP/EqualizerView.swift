//
//  EqualizerView.swift
//  Sonora
//
//  10-band equalizer with draggable band sliders, a live response curve and
//  per-band parametric controls.
//

import SwiftUI

struct EqualizerView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var routeMemory = EQRouteMemory.shared

    @State private var selectedBand: Int?
    @State private var showSavePreset = false
    @State private var newPresetName = ""

    private let gainRange: ClosedRange<Float> = -12...12

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                enableRow
                outputRow
                responseCurve
                bandSliders
                // The band list can be replaced underneath a selection (a
                // preset or per-device EQ loading), so re-check the index.
                if let index = selectedBand, settings.eqBands.indices.contains(index) {
                    bandDetail(index: index)
                }
                preampRow
                presetSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(themes.theme.background)
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newPresetName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                settings.saveCurrentAsPreset(named: name)
                newPresetName = ""
                Haptics.success()
            }
        }
    }

    // MARK: Rows

    private var enableRow: some View {
        HStack {
            Toggle(isOn: $settings.eqEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Equalizer").font(.system(size: 16, weight: .semibold))
                    Text(settings.selectedPresetName)
                        .font(.system(size: 12))
                        .foregroundStyle(themes.theme.textSecondary)
                }
            }
            .tint(themes.accent)
        }
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "hifispeaker.and.homepod")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(themes.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Output").font(.system(size: 15, weight: .semibold))
                    Text("EQ for: \(routeMemory.currentRouteLabel)")
                        .font(.system(size: 12))
                        .foregroundStyle(themes.theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Toggle("Separate EQ per device", isOn: $settings.eqPerDevice)
                .font(.system(size: 13))
                .tint(themes.accent)
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var responseCurve: some View {
        EQCurveView(bands: settings.eqBands,
                    preamp: Float(settings.eqPreampDB),
                    enabled: settings.eqEnabled,
                    selectedBand: selectedBand)
            .frame(height: 120)
            .cardBackground(themes.theme)
    }

    private var bandSliders: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(settings.eqBands.indices, id: \.self) { i in
                EQBandSlider(
                    band: bandBinding(i),
                    range: gainRange,
                    isSelected: selectedBand == i,
                    enabled: settings.eqEnabled,
                    onSelect: {
                        selectedBand = selectedBand == i ? nil : i
                        Haptics.select()
                    },
                    onChange: { settings.selectedPresetName = "Custom" }
                )
            }
        }
        .frame(height: 210)
    }

    private func bandDetail(index: Int) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Band \(index + 1) · \(frequencyLabel(bandBinding(index).wrappedValue.frequency))")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { selectedBand = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(themes.theme.textSecondary)
                }
            }

            Picker("Filter", selection: Binding(
                get: { bandBinding(index).wrappedValue.type },
                set: { newType in updateBand(index) { $0.type = newType }; settings.selectedPresetName = "Custom" }
            )) {
                ForEach(EQBandType.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(themes.accent)

            LabeledSlider(title: "Frequency",
                          value: Binding(
                            get: { Double(bandBinding(index).wrappedValue.frequency) },
                            set: { newValue in updateBand(index) { $0.frequency = Float(newValue) }; settings.selectedPresetName = "Custom" }),
                          range: 20...20000,
                          format: { frequencyLabel(Float($0)) },
                          onReset: {
                            // Bands past the standard ten have no default.
                            if EQPreset.standardFrequencies.indices.contains(index) {
                                updateBand(index) { $0.frequency = EQPreset.standardFrequencies[index] }
                            }
                          })

            LabeledSlider(title: "Bandwidth (Q)",
                          value: Binding(
                            get: { Double(bandBinding(index).wrappedValue.bandwidth) },
                            set: { newValue in updateBand(index) { $0.bandwidth = Float(newValue) }; settings.selectedPresetName = "Custom" }),
                          range: 0.05...5,
                          format: { String(format: "%.2f oct", $0) },
                          onReset: { updateBand(index) { $0.bandwidth = 0.5 } })

            Toggle("Bypass this band", isOn: Binding(
                get: { bandBinding(index).wrappedValue.bypass },
                set: { newValue in updateBand(index) { $0.bypass = newValue } }
            ))
            .font(.system(size: 13))
            .tint(themes.accent)
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var preampRow: some View {
        VStack(spacing: 8) {
            LabeledSlider(title: "Pre-amp",
                          value: $settings.eqPreampDB,
                          range: -12...12,
                          format: { String(format: "%+.1f dB", $0) },
                          onReset: { settings.eqPreampDB = 0 })

            VStack(alignment: .leading, spacing: 3) {
                Toggle("Auto pre-amp (prevent clipping)", isOn: $settings.eqAutoPreamp)
                    .font(.system(size: 13))
                    .tint(themes.accent)
                if settings.eqAutoPreamp {
                    Text(autoPreampCaption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(themes.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Presets").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { showSavePreset = true } label: {
                    Label("Save", systemImage: "plus.circle")
                        .font(.system(size: 13, weight: .medium))
                }
                Button { settings.resetEQ(); Haptics.tap() } label: {
                    Label("Flat", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(themes.accent)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                ForEach(settings.allPresets) { preset in
                    Button {
                        settings.apply(preset: preset)
                        selectedBand = nil
                        Haptics.select()
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 12.5, weight: settings.selectedPresetName == preset.name ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(settings.selectedPresetName == preset.name
                                        ? themes.accent : themes.theme.surfaceElevated,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(settings.selectedPresetName == preset.name
                                             ? .white : themes.theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !preset.isBuiltIn {
                            Button(role: .destructive) {
                                settings.deleteUserPreset(named: preset.name)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    /// How much the automatic pre-amp is pulling the level down right now.
    private var autoPreampCaption: String {
        guard settings.eqEnabled else { return "Applies while the equalizer is on" }
        let boost = EQResponse.maxBoostDB(bands: settings.eqBands)
        guard boost >= 0.05 else { return "No boost to compensate" }
        // DSPChain uses min(pre-amp, -boost), so a lower manual pre-amp wins.
        if settings.eqPreampDB <= -boost {
            return String(format: "Pre-amp already covers the +%.1f dB peak", boost)
        }
        return String(format: "\u{2212}%.1f dB applied", boost)
    }

    /// A binding to one band that tolerates the array changing size.
    ///
    /// `$settings.eqBands[i]` captures the index and traps when SwiftUI reads
    /// or writes it after the array has shrunk - which is what happens when a
    /// saved preset or per-device EQ with a different band count is loaded
    /// while the sliders are on screen. Out-of-range reads return a flat
    /// placeholder and out-of-range writes are dropped.
    private func bandBinding(_ index: Int) -> Binding<EQBand> {
        let settings = self.settings
        return Binding(
            get: {
                settings.eqBands.indices.contains(index)
                    ? settings.eqBands[index]
                    : EQBand(frequency: 1000)
            },
            set: { newValue in
                guard settings.eqBands.indices.contains(index) else { return }
                settings.eqBands[index] = newValue
            })
    }

    /// Edits one band in place, ignoring an index that no longer exists.
    private func updateBand(_ index: Int, _ change: (inout EQBand) -> Void) {
        guard settings.eqBands.indices.contains(index) else { return }
        change(&settings.eqBands[index])
    }

    private func frequencyLabel(_ hz: Float) -> String {
        hz >= 1000 ? String(format: "%.1fk", hz / 1000).replacingOccurrences(of: ".0k", with: "k")
                   : String(format: "%.0f", hz)
    }
}

// MARK: - Band slider

struct EQBandSlider: View {
    @Binding var band: EQBand
    let range: ClosedRange<Float>
    let isSelected: Bool
    let enabled: Bool
    let onSelect: () -> Void
    let onChange: () -> Void

    @EnvironmentObject private var themes: ThemeManager
    @State private var dragStartGain: Float?

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.0f", band.gain))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSelected ? themes.accent : themes.theme.textSecondary)

            GeometryReader { geo in
                let h = geo.size.height
                let span = Double(range.upperBound - range.lowerBound)
                let normalized = (Double(band.gain) - Double(range.lowerBound)) / span
                let knobY = h * (1 - normalized)

                ZStack(alignment: .top) {
                    Capsule()
                        .fill(themes.theme.surfaceElevated)
                        .frame(width: 5)
                        .frame(maxWidth: .infinity)

                    // Fill between centre and the knob
                    let centerY = h / 2
                    let top = min(centerY, knobY)
                    let height = abs(centerY - knobY)
                    Capsule()
                        .fill(enabled ? themes.accent.opacity(band.bypass ? 0.3 : 0.85)
                                      : themes.theme.textSecondary.opacity(0.35))
                        .frame(width: 5, height: max(1, height))
                        .frame(maxWidth: .infinity)
                        .offset(y: top)

                    Circle()
                        .fill(enabled ? themes.accent : themes.theme.textSecondary)
                        .frame(width: isSelected ? 16 : 12, height: isSelected ? 16 : 12)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: isSelected ? 2 : 0))
                        .frame(maxWidth: .infinity)
                        .offset(y: knobY - (isSelected ? 8 : 6))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartGain == nil { dragStartGain = band.gain }
                            let fraction = 1 - (value.location.y / h)
                            let raw = Float(fraction) * (range.upperBound - range.lowerBound) + range.lowerBound
                            let snapped = abs(raw) < 0.6 ? 0 : raw
                            band.gain = max(range.lowerBound, min(range.upperBound, snapped))
                            onChange()
                        }
                        .onEnded { _ in dragStartGain = nil; Haptics.tap() }
                )
            }

            Text(shortFrequency)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(themes.theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .opacity(enabled ? 1 : 0.5)
        .onTapGesture(count: 2) { band.gain = 0; onChange(); Haptics.tap() }
        .onLongPressGesture(minimumDuration: 0.3) { onSelect() }
    }

    private var shortFrequency: String {
        let hz = band.frequency
        if hz >= 1000 {
            let k = hz / 1000
            // Formatted, not `Int(...)`: that traps on NaN / infinity.
            return k == k.rounded() ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        }
        return String(format: "%.0f", hz)
    }
}

// MARK: - Response curve

struct EQCurveView: View {
    let bands: [EQBand]
    let preamp: Float
    let enabled: Bool
    let selectedBand: Int?

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        Canvas { context, size in
            let minHz = 20.0, maxHz = 20000.0
            let dbRange = 15.0

            func x(_ hz: Double) -> Double {
                (log10(hz) - log10(minHz)) / (log10(maxHz) - log10(minHz)) * size.width
            }
            func y(_ db: Double) -> Double {
                size.height / 2 - (db / dbRange) * (size.height / 2 - 6)
            }

            // Grid
            for hz in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                var p = Path()
                p.move(to: CGPoint(x: x(hz), y: 0))
                p.addLine(to: CGPoint(x: x(hz), y: size.height))
                context.stroke(p, with: .color(themes.theme.separator.opacity(0.5)), lineWidth: 0.5)
            }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0)))
            zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            context.stroke(zero, with: .color(themes.theme.separator), lineWidth: 1)

            // Curve
            var curve = Path()
            let steps = 220
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let hz = pow(10, log10(minHz) + t * (log10(maxHz) - log10(minHz)))
                let db = response(at: hz)
                let point = CGPoint(x: x(hz), y: y(db))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }

            let color = enabled ? themes.accent : themes.theme.textSecondary
            context.stroke(curve, with: .color(color), lineWidth: 2)

            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // Band markers
            for (i, band) in bands.enumerated() where !band.bypass {
                let point = CGPoint(x: x(Double(band.frequency)), y: y(Double(band.gain + preamp)))
                let r: Double = selectedBand == i ? 5 : 3
                let dot = Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(color))
            }
        }
        .padding(.vertical, 8)
    }

    /// Exact magnitude response of the band chain plus the pre-amp, in dB.
    private func response(at hz: Double) -> Double {
        let total = Double(preamp) + EQResponse.magnitudeDB(at: hz, bands: bands)
        return max(-15, min(15, total))
    }
}
