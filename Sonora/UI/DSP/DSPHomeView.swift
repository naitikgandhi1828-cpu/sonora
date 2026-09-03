//
//  DSPHomeView.swift
//  Sonora
//
//  Tabbed container for the equalizer and the rest of the effects rack.
//

import SwiftUI

struct DSPHomeView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Equalizer").tag(0)
                    Text("Effects").tag(1)
                    Text("Output").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                switch tab {
                case 0: EqualizerView()
                case 1: EffectsRackView()
                default: OutputView()
                }
            }
            .background(themes.theme.background)
            .navigationTitle("Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { settings.resetDSP(); Haptics.tap() }
                        .foregroundStyle(themes.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(themes.accent)
                }
            }
        }
        .preferredColorScheme(themes.colorScheme)
    }
}

// MARK: - Effects

struct EffectsRackView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                toneCard
                reverbCard
                tempoCard
                stereoCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(themes.theme.background)
    }

    // MARK: Tone

    private var toneCard: some View {
        card(title: "Tone", symbol: "dial.medium", isOn: $settings.toneEnabled) {
            LabeledSlider(title: "Bass", value: $settings.bassDB, range: -18...18,
                          format: { String(format: "%+.1f dB", $0) },
                          onReset: { settings.bassDB = 0 })
            LabeledSlider(title: "Bass Corner", value: $settings.bassFrequency, range: 40...400,
                          format: { String(format: "%.0f Hz", $0) },
                          onReset: { settings.bassFrequency = 120 })
            LabeledSlider(title: "Treble", value: $settings.trebleDB, range: -18...18,
                          format: { String(format: "%+.1f dB", $0) },
                          onReset: { settings.trebleDB = 0 })
            LabeledSlider(title: "Treble Corner", value: $settings.trebleFrequency, range: 2000...14000,
                          format: { String(format: "%.1f kHz", $0 / 1000) },
                          onReset: { settings.trebleFrequency = 6000 })
        }
    }

    // MARK: Reverb

    private var reverbCard: some View {
        card(title: "Reverb", symbol: "square.stack.3d.down.right", isOn: $settings.reverbEnabled) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Room")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themes.theme.textPrimary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(ReverbRoom.allCases) { room in
                        Button {
                            settings.reverbRoom = room
                            settings.reverbEnabled = true
                            Haptics.select()
                        } label: {
                            Text(room.label)
                                .font(.system(size: 12, weight: settings.reverbRoom == room ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(settings.reverbRoom == room ? themes.accent : themes.theme.surfaceElevated,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .foregroundStyle(settings.reverbRoom == room ? .white : themes.theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            LabeledSlider(title: "Wet Mix", value: $settings.reverbMix, range: 0...100,
                          format: { String(format: "%.0f%%", $0) },
                          onReset: { settings.reverbMix = 20 })

            if player.dsp.reverb.isAdvanced {
                LabeledSlider(title: "Decay", value: $settings.reverbDecay, range: 0.2...12,
                              format: { String(format: "%.1f s", $0) },
                              onReset: { settings.reverbDecay = 2.4 })
                LabeledSlider(title: "High-Frequency Damping", value: $settings.reverbDamping, range: 0...1,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              onReset: { settings.reverbDamping = 0.5 })
                LabeledSlider(title: "Pre-Delay", value: $settings.reverbPreDelay, range: 0...0.2,
                              format: { String(format: "%.0f ms", $0 * 1000) },
                              onReset: { settings.reverbPreDelay = 0.02 })
            } else {
                Text("This device only exposes preset reverb, so decay and damping are fixed by the room choice.")
                    .font(.system(size: 11))
                    .foregroundStyle(themes.theme.textSecondary)
            }
        }
    }

    // MARK: Tempo

    private var tempoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tempo & Pitch", systemImage: "speedometer")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Reset") {
                    settings.playbackRate = 1
                    settings.pitchCents = 0
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(themes.accent)
            }

            LabeledSlider(title: "Speed", value: $settings.playbackRate, range: 0.5...2.0, step: 0.01,
                          format: { String(format: "%.2f×", $0) },
                          onReset: { settings.playbackRate = 1 })

            HStack(spacing: 8) {
                ForEach([0.75, 0.9, 1.0, 1.1, 1.25, 1.5], id: \.self) { rate in
                    Chip(title: String(format: "%.2g×", rate),
                         isSelected: abs(settings.playbackRate - rate) < 0.005) {
                        settings.playbackRate = rate
                        Haptics.select()
                    }
                }
            }

            Toggle("Link pitch to speed (varispeed)", isOn: $settings.tempoPitchLinked)
                .font(.system(size: 13))
                .tint(themes.accent)

            if !settings.tempoPitchLinked {
                LabeledSlider(title: "Pitch", value: $settings.pitchCents, range: -1200...1200, step: 10,
                              format: { String(format: "%+.0f cents (%+.1f st)", $0, $0 / 100) },
                              onReset: { settings.pitchCents = 0 })
            }
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    // MARK: Stereo

    private var stereoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Stereo Field", systemImage: "airpodsmax")
                .font(.system(size: 15, weight: .semibold))

            LabeledSlider(title: "Width", value: $settings.stereoWidth, range: 0...2,
                          format: { $0 < 0.02 ? "Mono" : String(format: "%.0f%%", $0 * 100) },
                          onReset: { settings.stereoWidth = 1 })

            LabeledSlider(title: "Balance", value: $settings.balance, range: -1...1,
                          format: { v in
                            abs(v) < 0.01 ? "Center"
                            : (v < 0 ? String(format: "L %.0f%%", -v * 100)
                                     : String(format: "R %.0f%%", v * 100)) },
                          onReset: { settings.balance = 0 })

            Toggle("Mono downmix", isOn: $settings.monoDownmix)
                .font(.system(size: 13))
                .tint(themes.accent)
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    // MARK: Helper

    @ViewBuilder
    private func card<Content: View>(title: String,
                                     symbol: String,
                                     isOn: Binding<Bool>,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: isOn) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(themes.accent)

            content()
                .disabled(!isOn.wrappedValue)
                .opacity(isOn.wrappedValue ? 1 : 0.45)
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }
}

// MARK: - Output

struct OutputView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var session = AudioSessionManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                routeCard
                gainCard
                limiterCard
                replayGainCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(themes.theme.background)
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Output", systemImage: session.routeSymbol)
                .font(.system(size: 15, weight: .semibold))
            infoRow("Device", session.currentRouteName)
            infoRow("Hardware rate", "\(Int(session.hardwareSampleRate)) Hz")
            infoRow("Output latency", String(format: "%.1f ms", session.outputLatency * 1000))
            Text("Sonora asks iOS to run the hardware at each file's native sample rate. iOS grants that where it can; Bluetooth routes usually stay fixed.")
                .font(.system(size: 11))
                .foregroundStyle(themes.theme.textSecondary)
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var gainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Master", systemImage: "speaker.wave.3")
                .font(.system(size: 15, weight: .semibold))
            LabeledSlider(title: "Pre-amp", value: $settings.masterPreampDB, range: -24...12,
                          format: { String(format: "%+.1f dB", $0) },
                          onReset: { settings.masterPreampDB = 0 })
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var limiterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settings.limiterEnabled) {
                Label("Limiter", systemImage: "waveform.badge.exclamationmark")
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(themes.accent)

            Group {
                LabeledSlider(title: "Ceiling", value: $settings.limiterThresholdDB, range: -12...0,
                              format: { String(format: "%.1f dBFS", $0) },
                              onReset: { settings.limiterThresholdDB = -0.5 })
                LabeledSlider(title: "Release", value: $settings.limiterReleaseMS, range: 10...600,
                              format: { String(format: "%.0f ms", $0) },
                              onReset: { settings.limiterReleaseMS = 120 })
                Text("Catches the peaks that heavy EQ or a positive pre-amp would otherwise clip. Leave this on.")
                    .font(.system(size: 11))
                    .foregroundStyle(themes.theme.textSecondary)
            }
            .disabled(!settings.limiterEnabled)
            .opacity(settings.limiterEnabled ? 1 : 0.45)
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var replayGainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Replay Gain", systemImage: "speaker.wave.2.circle")
                .font(.system(size: 15, weight: .semibold))

            Picker("Mode", selection: $settings.replayGainMode) {
                ForEach(ReplayGainMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(themes.accent)

            if settings.replayGainMode != .off {
                LabeledSlider(title: "Pre-amp", value: $settings.replayGainPreampDB, range: -12...12,
                              format: { String(format: "%+.1f dB", $0) },
                              onReset: { settings.replayGainPreampDB = 0 })
                LabeledSlider(title: "Fallback for untagged tracks", value: $settings.replayGainFallbackDB,
                              range: -12...6,
                              format: { String(format: "%+.1f dB", $0) },
                              onReset: { settings.replayGainFallbackDB = -6 })
                Toggle("Prevent clipping using peak tag", isOn: $settings.preventClipping)
                    .font(.system(size: 13)).tint(themes.accent)
                Toggle("Measure loudness for untagged tracks", isOn: $settings.autoAnalyzeGain)
                    .font(.system(size: 13)).tint(themes.accent)
            }
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(themes.theme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 13, design: .monospaced))
        }
        .font(.system(size: 13))
    }
}

// MARK: - Sleep timer

struct SleepTimerView: View {

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var customMinutes: Double = 45

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if player.sleepTimer.isActive {
                        activeCard
                    } else {
                        presetGrid
                        customCard
                        optionsCard
                    }
                }
                .padding(18)
            }
            .background(themes.theme.background)
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(themes.accent)
                }
            }
        }
        .preferredColorScheme(themes.colorScheme)
    }

    private var activeCard: some View {
        VStack(spacing: 16) {
            Text(player.sleepTimer.formattedRemaining)
                .font(.system(size: 52, weight: .thin, design: .rounded))
                .foregroundStyle(themes.accent)
                .monospacedDigit()

            ProgressView(value: player.sleepTimer.totalDuration > 0
                         ? 1 - player.sleepTimer.remaining / player.sleepTimer.totalDuration : 0)
                .tint(themes.accent)

            HStack(spacing: 10) {
                ForEach([5.0, 15.0, 30.0], id: \.self) { extra in
                    Button {
                        player.sleepTimer.extend(minutes: extra)
                        Haptics.tap()
                    } label: {
                        Text("+\(Int(extra))m")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(themes.theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(themes.theme.textPrimary)
                }
            }

            Button(role: .destructive) {
                player.sleepTimer.cancel()
                settings.masterPreampDB = 0
                Haptics.tap()
            } label: {
                Text("Cancel Timer")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .cardBackground(themes.theme)
    }

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 10)], spacing: 10) {
            ForEach(SleepTimer.presets, id: \.self) { minutes in
                Button {
                    start(minutes)
                } label: {
                    VStack(spacing: 2) {
                        Text("\(Int(minutes))").font(.system(size: 20, weight: .semibold))
                        Text("min").font(.system(size: 10)).foregroundStyle(themes.theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(themes.theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(themes.theme.textPrimary)
            }
        }
    }

    private var customCard: some View {
        VStack(spacing: 12) {
            LabeledSlider(title: "Custom", value: $customMinutes, range: 1...240, step: 1,
                          format: { String(format: "%.0f min", $0) })
            Button { start(customMinutes) } label: {
                Text("Start Timer")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(themes.accent, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Fade out before stopping", isOn: $settings.sleepFadeOut)
                .tint(themes.accent)
            if settings.sleepFadeOut {
                LabeledSlider(title: "Fade length", value: $settings.sleepFadeSeconds, range: 3...120, step: 1,
                              format: { String(format: "%.0f s", $0) })
            }
            Toggle("Finish the current track first", isOn: $settings.sleepFinishTrack)
                .tint(themes.accent)
        }
        .font(.system(size: 13))
        .padding(14)
        .cardBackground(themes.theme)
        .foregroundStyle(themes.theme.textPrimary)
    }

    private func start(_ minutes: Double) {
        player.sleepTimer.start(minutes: minutes,
                                fadeSeconds: settings.sleepFadeOut ? settings.sleepFadeSeconds : 0,
                                finishTrack: settings.sleepFinishTrack)
        Haptics.success()
        dismiss()
    }
}
