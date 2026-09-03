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

    @State private var showFolderPicker = false
    @State private var confirmWipe = false
    @State private var artworkSize: Int64 = 0

    var body: some View {
        NavigationStack {
            List {
                foldersSection
                playbackSection
                appearanceSection
                librarySection
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
                Button("Erase", role: .destructive) { library.wipeLibrary() }
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
                .swipeActions {
                    Button(role: .destructive) { library.removeRoot(root) } label: {
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
            Text("Sonora reads files in place. You can also copy music into the Sonora folder in the Files app.")
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
            LabeledSlider(title: "Skip step", value: $settings.seekStepSeconds, range: 5...60, step: 5,
                          format: { String(format: "%.0f s", $0) })
            LabeledSlider(title: "Previous restarts track after", value: $settings.rewindOnPrevSeconds,
                          range: 0...20, step: 1,
                          format: { $0 == 0 ? "Never" : String(format: "%.0f s", $0) })
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
            HStack { Text("Version"); Spacer(); Text("1.0").foregroundStyle(.secondary) }
            HStack { Text("Tracks"); Spacer(); Text("\(library.tracks.count)").foregroundStyle(.secondary) }
            HStack { Text("Total time"); Spacer(); Text(library.totalDuration.longFormat).foregroundStyle(.secondary) }
        } header: {
            Text("About")
        } footer: {
            Text("Sonora plays the formats iOS can decode natively: MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF and CAF. Formats like Opus, WMA, APE and DSD need a bundled decoder — see the project README.")
        }
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
