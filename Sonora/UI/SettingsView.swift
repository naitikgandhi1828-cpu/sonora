//
//  SettingsView.swift
//  Sonora
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var artwork: ArtworkFinder
    @EnvironmentObject private var player: PlaybackController

    @State private var showFolderPicker = false
    /// Folder waiting for the user to confirm its removal.
    @State private var folderToRemove: FolderRoot?
    @State private var confirmWipe = false
    @State private var artworkSize: Int64 = 0

    var body: some View {
        NavigationStack {
            List {
                foldersSection
                driveSection
                duplicatesSection
                batterySection
                playbackSection
                appearanceSection
                librarySection
                artworkSection
                storageSection
                aboutSection
            }
            .themedList(themes.theme)
            .themedNavBar(themes.theme)
            .miniPlayerClearance()
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await library.addRoot(url: url) }
                }
            }
            .alert("Erase library?", isPresented: $confirmWipe) {
                Button("Cancel", role: .cancel) {}
                Button("Erase", role: .destructive) {
                    library.wipeLibrary()
                    // The queue (and whatever is playing) now points at tracks
                    // that no longer exist; drop them like a removed folder.
                    player.pruneQueue()
                }
            } message: {
                Text("This removes Sonora's index, artwork cache and playlists. Your audio files are never touched.")
            }
            .task { artworkSize = ArtworkStore.shared.diskUsageBytes }
        }
    }

    // MARK: Sections

    private var foldersSection: some View {
        Section {
            ForEach(library.roots) { root in
                VStack(alignment: .leading, spacing: 3) {
                    Text(root.displayName).font(.system(size: 15))
                    Text("\(root.trackCount) tracks · added \(root.dateAdded.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    // Visible way in: swipe-to-remove alone was too hidden.
                    Menu {
                        Button { Task { await library.rescan(rootID: root.id) } } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) { folderToRemove = root } label: {
                            Label("Remove from Library", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(themes.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { folderToRemove = root } label: {
                        Label("Remove from Library", systemImage: "trash")
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { folderToRemove = root } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    Button { Task { await library.rescan(rootID: root.id) } } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .tint(themes.accent)
                }
            }
            Button { showFolderPicker = true } label: {
                Label("Add Folder…", systemImage: "folder.badge.plus")
            }
        } header: {
            Text("Music Folders")
        } footer: {
            Text("Sonora reads files in place. Tap ••• on a folder to rescan or remove it. Removing a folder only takes it out of Sonora — your music files are never deleted. You can also copy music into the Sonora folder in the Files app.")
        }
        .confirmationDialog("Remove “\(folderToRemove?.displayName ?? "")” from Sonora?",
                            isPresented: Binding(get: { folderToRemove != nil },
                                                 set: { if !$0 { folderToRemove = nil } }),
                            titleVisibility: .visible,
                            presenting: folderToRemove) { root in
            Button("Remove Folder", role: .destructive) {
                library.removeRoot(root)
                player.pruneQueue()
                folderToRemove = nil
            }
            Button("Cancel", role: .cancel) { folderToRemove = nil }
        } message: { root in
            Text("Its \(root.trackCount) tracks leave your library and playlists. The files themselves stay where they are, and you can add the folder again any time.")
        }
        .themedRow(themes.theme)
    }

    private var driveSection: some View {
        Section {
            NavigationLink {
                GoogleDriveView()
            } label: {
                Label("Google Drive", systemImage: "icloud.and.arrow.down")
            }
        } header: {
            Text("Cloud Music")
        } footer: {
            Text("Connect Google Drive to download songs from it. They are saved on your iPhone, show up in your library and play without internet.")
        }
        .tint(themes.accent)
        .themedRow(themes.theme)
    }

    private var duplicatesSection: some View {
        Section {
            NavigationLink {
                DuplicateSettingsView()
            } label: {
                HStack {
                    Label("Duplicate Songs", systemImage: "square.on.square")
                    Spacer()
                    if !library.duplicateQuestions.isEmpty {
                        Text("\(library.duplicateQuestions.count) to review")
                            .font(.system(size: 13))
                            .foregroundStyle(themes.accent)
                    } else if !library.mergedGroups.isEmpty {
                        Text("\(library.mergedGroups.count) merged")
                            .font(.system(size: 13))
                            .foregroundStyle(themes.theme.textSecondary)
                    }
                }
            }
        } footer: {
            Text("The same song stored twice is shown once. Sonora asks when it is not sure, and remembers your answer.")
        }
        .tint(themes.accent)
        .themedRow(themes.theme)
    }

    private var playbackSection: some View {
        Section("Playback") {
            Toggle("Gapless playback", isOn: $settings.gaplessEnabled)
            Toggle("Crossfade", isOn: $settings.crossfadeEnabled)
            if settings.crossfadeEnabled {
                LabeledSlider(title: "Crossfade length", value: $settings.crossfadeSeconds,
                              range: 1...12, step: 0.5,
                              format: { String(format: "%.1f s", $0) })
                Toggle("Only when skipping manually", isOn: $settings.crossfadeOnManualSkipOnly)
            }
            Toggle("Fade on pause and resume", isOn: $settings.fadeOnPauseResume)
            Toggle("Pause when headphones disconnect", isOn: $settings.pauseOnDisconnect)
            Toggle("Resume when headphones connect", isOn: $settings.resumeOnHeadphones)
            Toggle("Restore last track on launch", isOn: $settings.resumeOnLaunch)
            Toggle("Lock screen skips seconds, not songs", isOn: $settings.lockScreenSkipButtons)
            LabeledSlider(title: "Skip step", value: $settings.seekStepSeconds, range: 5...60, step: 5,
                          format: { String(format: "%.0f s", $0) })
            LabeledSlider(title: "Previous restarts track after", value: $settings.rewindOnPrevSeconds,
                          range: 0...20, step: 1,
                          format: { $0 == 0 ? "Never" : String(format: "%.0f s", $0) })
        }
        .tint(themes.accent)
        .themedRow(themes.theme)
    }

    private var batterySection: some View {
        Section {
            Picker("Battery Saver", selection: $settings.powerMode) {
                ForEach(PowerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if settings.batterySaverActive {
                Label("Battery Saver is on", systemImage: "battery.100percent.bolt")
                    .font(.system(size: 13))
                    .foregroundStyle(themes.accent)
            }
        } header: {
            Text("Battery")
        } footer: {
            Text("Battery Saver hides the spectrum visualizer, lets the screen sleep, caps playback at 48 kHz (hi-res above that only matters with a wired USB DAC), stops the \"now playing\" bars from animating, and only builds waveforms or measures loudness while charging. AirPods, Bluetooth and the built-in speaker run at 48 kHz or below anyway, so they sound the same.")
        }
        .tint(themes.accent)
        .themedRow(themes.theme)
    }

    private var appearanceSection: some View {
        Section {
            NavigationLink {
                ThemePickerView()
            } label: {
                HStack {
                    Text("Theme")
                    Spacer()
                    Text(themes.theme.name).foregroundStyle(themes.theme.textSecondary)
                }
            }
            NavigationLink {
                AppIconPickerView()
            } label: {
                Label("App Icon", systemImage: "app.badge")
            }
            NavigationLink {
                VisualEffectsView()
            } label: {
                Label("Visual Effects", systemImage: "sparkles")
            }
            Picker("Font style", selection: $settings.fontStyle) {
                ForEach(FontStyle.allCases) { style in
                    Text(style.label).fontDesign(style.design).tag(style)
                }
            }
            Toggle("Tint player from album art", isOn: $settings.useAlbumArtColors)
            Toggle("Waveform seek bar", isOn: $settings.showWaveformSeekBar)
            Toggle("Keep screen awake while playing", isOn: $settings.keepScreenAwake)
        } header: {
            Text("Appearance")
        } footer: {
            Text("The theme colours the whole app. \"Tint player from album art\" only recolours the Now Playing screen and mini player to match the cover.")
        }
        .tint(themes.accent)
        .themedRow(themes.theme)
    }

    private var librarySection: some View {
        Section("Library") {
            Toggle("Parse .cue sheets", isOn: $settings.parseCueSheets)
            Toggle("Import .m3u playlists", isOn: $settings.importM3U)
            LabeledSlider(title: "Ignore tracks shorter than", value: $settings.minimumTrackSeconds,
                          range: 0...60, step: 1,
                          format: { $0 == 0 ? "No limit" : String(format: "%.0f s", $0) })
            Button {
                Task { await library.rescanAll() }
            } label: {
                Label("Rescan All Folders", systemImage: "arrow.clockwise")
            }
            .disabled(library.roots.isEmpty || library.isScanning)
        }
        .tint(themes.accent)
        .themedRow(themes.theme)
    }

    private var artworkSection: some View {
        Section {
            Toggle("Download missing artwork", isOn: $settings.downloadMissingArtwork)

            Button {
                Task { await artwork.findMissingArtwork() }
            } label: {
                HStack {
                    Label("Find Missing Artwork", systemImage: "photo.on.rectangle.angled")
                    Spacer()
                    if artwork.isRunning { ProgressView() }
                }
            }
            .disabled(artwork.isRunning || library.tracks.isEmpty)

            if artwork.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: artwork.progress)
                    Text(artwork.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button("Stop", role: .cancel) { artwork.cancel() }
            } else if !artwork.status.isEmpty {
                Text(artwork.status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Album Art")
        } footer: {
            Text("Sonora first looks for a cover image beside your files and for artwork tagged into another track of the same album. Only when that fails, and only with the switch above on, does it ask Apple's public iTunes Search catalogue — sending the artist and album name and nothing else. Turn it off to keep Sonora entirely offline.")
        }
        .tint(themes.accent)
        .themedRow(themes.theme)
    }

    private var storageSection: some View {
        Section("Storage") {
            HStack {
                Text("Artwork cache")
                Spacer()
                Text(artworkSize.byteSize).foregroundStyle(.secondary)
            }
            Button("Clear Artwork Cache") {
                ArtworkStore.shared.clear()
                artworkSize = 0
            }
            Button("Clear Waveform Cache") {
                Task { await WaveformAnalyzer.shared.clearCache() }
            }
            Button("Erase Library Index", role: .destructive) { confirmWipe = true }
        }
        .tint(themes.accent)
        .themedRow(themes.theme)
    }

    private var aboutSection: some View {
        Section {
            HStack { Text("Version"); Spacer(); Text(Self.appVersion).foregroundStyle(themes.theme.textSecondary) }
            if let updated = SigningStatus.updatedAt {
                HStack {
                    Text("Last updated")
                    Spacer()
                    Text(SigningStatus.formatted(updated)).foregroundStyle(themes.theme.textSecondary)
                }
            }
            if let expiry = SigningStatus.expiry {
                HStack {
                    Text("Works until")
                    Spacer()
                    Text(SigningStatus.formatted(expiry))
                        .foregroundStyle((SigningStatus.daysLeft ?? 9) < 2 ? Color.red : Color.secondary)
                }
            }
            HStack { Text("Tracks"); Spacer(); Text("\(library.tracks.count)").foregroundStyle(.secondary) }
            HStack { Text("Total time"); Spacer(); Text(library.totalDuration.longFormat).foregroundStyle(.secondary) }
        } header: {
            Text("About")
        } footer: {
            Text("You get a notification when your laptop updates Sonora, and reminders 2 days, 1 day and 3 hours before it expires. Sonora plays the formats iOS can decode natively: MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF and CAF. Formats like Opus, WMA, APE and DSD need a bundled decoder — see the project README.")
        }
        .themedRow(themes.theme)
    }
}

extension SettingsView {
    /// Read from the bundle rather than typed in, so it cannot drift away from
    /// what the build actually shipped.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String) ?? "—"
        guard let build = info["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }
}

struct ThemePickerView: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: AppSettings

    @State private var accentDraft: Color = .orange

    var body: some View {
        List {
            Section {
                Toggle("Custom accent colour", isOn: Binding(
                    get: { themes.customAccent != nil },
                    set: { on in
                        themes.setCustomAccent(on ? accentDraft : nil)
                        Haptics.select()
                    }))
                if themes.customAccent != nil {
                    ColorPicker("Accent", selection: Binding(
                        get: { themes.customAccent ?? accentDraft },
                        set: { color in
                            accentDraft = color
                            themes.setCustomAccent(color)
                        }), supportsOpacity: false)
                    swatchRow
                }
            } header: {
                Text("Accent")
            } footer: {
                Text("Replaces the theme's highlight colour everywhere. With \"Tint player from album art\" on, the Now Playing screen still follows the cover.")
            }
            .themedRow(themes.theme)

            Section("Dark") {
                ForEach(Theme.dark) { row($0) }
            }
            .themedRow(themes.theme)
            Section("Light") {
                ForEach(Theme.light) { row($0) }
            }
            .themedRow(themes.theme)
        }
        .tint(themes.accent)
        .themedList(themes.theme)
        .themedNavBar(themes.theme)
        .miniPlayerClearance()
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { accentDraft = themes.customAccent ?? themes.baseTheme.accent }
    }

    /// Quick picks so nobody has to fiddle with the colour wheel.
    private var swatchRow: some View {
        let picks: [Color] = [
            Theme.rgb(255, 135, 76), Theme.rgb(239, 58, 72), Theme.rgb(255, 68, 173),
            Theme.rgb(178, 140, 255), Theme.rgb(94, 158, 255), Theme.rgb(38, 198, 218),
            Theme.rgb(76, 217, 148), Theme.rgb(232, 190, 92)
        ]
        return HStack(spacing: 10) {
            ForEach(Array(picks.enumerated()), id: \.offset) { _, color in
                Button {
                    accentDraft = color
                    themes.setCustomAccent(color)
                    Haptics.select()
                } label: {
                    Circle().fill(color)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.primary.opacity(
                            themes.customAccent?.hexString == color.hexString ? 0.9 : 0), lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ theme: Theme) -> some View {
        Button {
            themes.select(theme)
            Haptics.select()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(theme.background)
                    Circle().fill(theme.gradient).frame(width: 22, height: 22)
                }
                .frame(width: 46, height: 46)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.separator, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.name)
                    // A strip of the theme's own colours, so a theme can be
                    // judged before picking it.
                    HStack(spacing: 3) {
                        ForEach(Array([theme.surface, theme.textPrimary, theme.accent, theme.accentSecondary]
                                        .enumerated()), id: \.offset) { _, c in
                            Capsule().fill(c).frame(width: 14, height: 4)
                                .overlay(Capsule().stroke(theme.separator, lineWidth: 0.5))
                        }
                    }
                }
                Spacer()
                if settings.themeID == theme.id {
                    Image(systemName: "checkmark").foregroundStyle(themes.accent)
                }
            }
        }
        .foregroundStyle(themes.theme.textPrimary)
    }
}

// MARK: - Visual effects

struct VisualEffectsView: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                Picker("Shape", selection: $settings.artworkShape) {
                    ForEach(ArtworkShape.allCases) { shape in
                        Label(shape.label, systemImage: shape.symbol).tag(shape)
                    }
                }
                Toggle("Breathing artwork", isOn: $settings.breathingArtwork)
                Toggle("Coloured glow", isOn: $settings.artworkGlow)
            } header: {
                Text("Now Playing Artwork")
            } footer: {
                Text("Breathing shrinks the cover slightly when paused. Glow swaps the dark shadow for one in the album's colour.")
            }
            .themedRow(themes.theme)

            Section {
                Toggle("Blurred art background", isOn: $settings.blurredArtBackground)
                Toggle("Ambient colour glow", isOn: $settings.ambientBackground)
                if settings.ambientBackground && settings.batterySaverActive {
                    Label("Battery Saver is on — the glow stays still", systemImage: "battery.100percent.bolt")
                        .font(.system(size: 13))
                        .foregroundStyle(themes.accent)
                }
            } header: {
                Text("Background")
            } footer: {
                Text("Ambient glow slowly drifts soft album colours behind the player while music plays. It stops moving when paused or under Battery Saver.")
            }
            .themedRow(themes.theme)

            Section {
                Toggle("Spectrum visualizer", isOn: $settings.showVisualizer)
                if settings.showVisualizer {
                    Picker("Style", selection: $settings.visualizerStyle) {
                        ForEach(VisualizerStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Visualizer")
            } footer: {
                Text("Bars, bars mirrored from the centre, or a smooth wave. Hidden automatically under Battery Saver.")
            }
            .themedRow(themes.theme)

            Section {
                Toggle("Glass controls", isOn: $settings.glassControls)
            } header: {
                Text("Controls")
            } footer: {
                Text("Frosted-glass panels behind the player buttons and the mini player. Uses a little more battery than the plain look.")
            }
            .themedRow(themes.theme)
        }
        .tint(themes.accent)
        .themedList(themes.theme)
        .themedNavBar(themes.theme)
        .miniPlayerClearance()
        .navigationTitle("Visual Effects")
        .navigationBarTitleDisplayMode(.inline)
    }
}
