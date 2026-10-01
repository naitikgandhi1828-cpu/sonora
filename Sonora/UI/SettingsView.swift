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
                batterySection
                playbackSection
                appearanceSection
                librarySection
                artworkSection
                storageSection
                aboutSection
            }
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
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            NavigationLink {
                ThemePickerView()
            } label: {
                HStack {
                    Text("Theme")
                    Spacer()
                    Text(themes.theme.name).foregroundStyle(.secondary)
                }
            }
            Toggle("Tint from album art", isOn: $settings.useAlbumArtColors)
            Toggle("Blurred art background", isOn: $settings.blurredArtBackground)
            Toggle("Waveform seek bar", isOn: $settings.showWaveformSeekBar)
            Toggle("Spectrum visualizer", isOn: $settings.showVisualizer)
            Toggle("Keep screen awake while playing", isOn: $settings.keepScreenAwake)
        }
        .tint(themes.accent)
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
    }

    private var aboutSection: some View {
        Section {
            HStack { Text("Version"); Spacer(); Text(Self.appVersion).foregroundStyle(.secondary) }
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
            Text("You get a notification when Sideloadly refreshes Sonora, and reminders 2 days, 1 day and 3 hours before it expires. Sonora plays the formats iOS can decode natively: MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF and CAF. Formats like Opus, WMA, APE and DSD need a bundled decoder — see the project README.")
        }
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

    var body: some View {
        List(Theme.all) { theme in
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

                    Text(theme.name)
                    Spacer()
                    if themes.theme.id == theme.id {
                        Image(systemName: "checkmark").foregroundStyle(theme.accent)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}
