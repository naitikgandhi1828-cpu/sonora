//
//  LyricsView.swift
//  Sonora
//
//  Shows the playing song's unsynchronised lyrics. Follows the player, so
//  the sheet updates when the next song starts.
//
//  When a song has none, "Search Online" asks LRCLIB (a free lyrics
//  database) and shows what it found for review; "Save to Song" stores it
//  through the same tag-edit path as the tag editor.
//

import SwiftUI

struct LyricsView: View {

    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var found: OnlineLyrics?
    @State private var foundForTrackID: UUID?
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        let track = player.currentTrack
        let lyrics = (track?.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let theme = themes.theme

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let track {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.displayTitle)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(theme.textPrimary)
                            Text(track.displayArtist)
                                .font(.subheadline)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    if !lyrics.isEmpty {
                        if let message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                        Text(lyrics)
                            .font(.system(size: 18, design: .serif))
                            .lineSpacing(7)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                    } else if let track, let found, foundForTrackID == track.id {
                        foundLyrics(found, for: track)
                    } else {
                        emptyState(track)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .themedNavBar(theme)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(themes.accent)
        .themedSheet(themes)
        .onChange(of: player.currentTrack?.id) { _, _ in
            // The next song started: drop the previous song's search.
            task?.cancel()
            found = nil
            foundForTrackID = nil
            isSearching = false
            message = nil
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: - States

    @ViewBuilder
    private func emptyState(_ track: Track?) -> some View {
        let theme = themes.theme
        VStack(alignment: .leading, spacing: 14) {
            Text("This song has no lyrics. You can add them with Edit Tags, or look them up online.")
                .foregroundStyle(theme.textSecondary)
            if let track {
                Button {
                    search(for: track)
                } label: {
                    HStack(spacing: 8) {
                        if isSearching {
                            ProgressView()
                        } else {
                            Image(systemName: "text.magnifyingglass")
                        }
                        Text(isSearching ? "Searching…" : "Search Online")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
            }
            Text("Searches LRCLIB, a free lyrics database. Only the title, artist, album and length are sent.")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func foundLyrics(_ found: OnlineLyrics, for track: Track) -> some View {
        let theme = themes.theme
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Found on \(found.source)", systemImage: "checkmark.seal")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(themes.accent)
                Text(matchLine(found))
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                Text("Check they're right before saving.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }

            HStack(spacing: 10) {
                Button {
                    save(found.text, to: track)
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView() }
                        Text(isSaving ? "Saving…" : "Save to Song")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)

                Button("Discard") {
                    self.found = nil
                    foundForTrackID = nil
                    message = nil
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
            }

            Text(found.text)
                .font(.system(size: 18, design: .serif))
                .lineSpacing(7)
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func matchLine(_ found: OnlineLyrics) -> String {
        var parts = [found.trackName, found.artistName, found.albumName].filter { !$0.isEmpty }
        if let d = found.duration, d > 0 { parts.append(d.timecode) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func search(for track: Track) {
        guard !isSearching else { return }
        isSearching = true
        message = nil
        let id = track.id
        var title = track.title
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = MetadataReader.parseFilename((track.fileName as NSString).deletingPathExtension).title
        }
        let artist = track.artist.isEmpty ? track.albumArtist : track.artist
        let album = track.album
        let duration: TimeInterval? = track.duration > 0 ? track.duration : nil
        task?.cancel()
        task = Task {
            do {
                let result = try await LRCLibLookup.find(artist: artist, title: title, album: album, duration: duration)
                if Task.isCancelled || player.currentTrack?.id != id { return }
                if result.isInstrumental {
                    message = "LRCLIB lists this song as an instrumental."
                } else {
                    found = result
                    foundForTrackID = id
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                if let e = error as? TagLookupError, e == .noResults {
                    message = "No lyrics found for this song."
                } else {
                    message = error.localizedDescription
                }
            }
            isSearching = false
        }
    }

    private func save(_ text: String, to track: Track) {
        guard !isSaving else { return }
        isSaving = true
        message = nil
        var tags = TagSet()
        tags.lyrics = text
        let write = MediaLibrary.canWriteTags(to: track)
        Task {
            let result = await library.applyTagEdit(trackIDs: [track.id],
                                                    tags: tags,
                                                    artwork: .keep,
                                                    writeToFiles: write)
            isSaving = false
            if let failure = result.failures.first {
                message = "Saved in Sonora, but the file couldn't be updated: \(failure.1)"
            } else {
                // The player picks up the edited track, so the lyrics now
                // show as the song's own.
                found = nil
                foundForTrackID = nil
                Haptics.success()
            }
        }
    }
}
