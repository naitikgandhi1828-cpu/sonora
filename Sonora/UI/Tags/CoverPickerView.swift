//
//  CoverPickerView.swift
//  Sonora
//
//  "Find Cover Online" in the tag editor: searches iTunes, Deezer and
//  MusicBrainz / Cover Art Archive together and shows every cover found as
//  a grid, so the user picks the right one instead of getting whatever the
//  first catalogue returned. Runs only when the user opens it.
//

import SwiftUI

struct CoverPickerView: View {

    let artist: String
    let album: String
    let fallbackTerm: String
    /// Called with JPEG data (at most 1200 px) for the chosen cover.
    let onPick: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themes: ThemeManager

    @AppStorage(LookupSource.itunes.enabledKey) private var useITunes = true
    @AppStorage(LookupSource.deezer.enabledKey) private var useDeezer = true
    @AppStorage(LookupSource.musicbrainz.enabledKey) private var useMusicBrainz = true

    @State private var covers: [CoverCandidate] = []
    @State private var failures: [LookupSource: String] = [:]
    @State private var phase: Phase = .idle
    @State private var downloadingID: UUID?
    @State private var downloadError: String?
    @State private var searchTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case idle, searching, loaded
        case failed(String)
    }

    private var sources: [LookupSource] {
        LookupSource.allCases.filter { source in
            switch source {
            case .itunes: return useITunes
            case .deezer: return useDeezer
            case .musicbrainz: return useMusicBrainz
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12)]

    var body: some View {
        let theme = themes.theme
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    switch phase {
                    case .idle, .searching:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching \(sources.count) catalogue\(sources.count == 1 ? "" : "s")…")
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    case .failed(let message):
                        VStack(spacing: 10) {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(theme.textSecondary)
                            Button("Try Again") { search() }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    case .loaded:
                        if covers.isEmpty {
                            Text("No covers found for this album.")
                                .foregroundStyle(theme.textSecondary)
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity)
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(covers) { cover in
                                    Button { choose(cover) } label: { tile(cover) }
                                        .buttonStyle(.plain)
                                        .disabled(downloadingID != nil)
                                }
                            }
                        }
                    }

                    if let downloadError {
                        Label(downloadError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(theme.textSecondary)
                    }

                    if !failures.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(LookupSource.allCases.filter { failures[$0] != nil }) { source in
                                Text("\(source.displayName) didn't answer: \(failures[source] ?? "")")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                    }

                    Text("Only the album and artist names are sent. Covers from MusicBrainz come from the Cover Art Archive; some releases have none and show a blank tile.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(16)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Choose a Cover")
            .navigationBarTitleDisplayMode(.inline)
            .themedNavBar(theme)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        searchTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .tint(themes.accent)
        .themedSheet(themes)
        .onAppear {
            if phase == .idle { search() }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LookupText.isPlaceholder(album) ? fallbackTerm : album)
                .font(.headline)
                .foregroundStyle(themes.theme.textPrimary)
                .lineLimit(2)
            if !LookupText.isPlaceholder(artist) {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(themes.theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func tile(_ cover: CoverCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                AsyncImage(url: cover.thumbnailURL) { imagePhase in
                    if let image = imagePhase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if imagePhase.error != nil {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            ProgressView()
                        }
                    }
                }
                if downloadingID == cover.id {
                    Color.black.opacity(0.35)
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(cover.album.isEmpty ? "Untitled" : cover.album)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(themes.theme.textPrimary)
                .lineLimit(1)
            Text([cover.artist, cover.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(themes.theme.textSecondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                SourceBadge(source: cover.source)
                Text(cover.sizeNote)
                    .font(.system(size: 9))
                    .foregroundStyle(themes.theme.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func search() {
        searchTask?.cancel()
        let sources = self.sources
        guard !sources.isEmpty else {
            phase = .failed("Every catalogue is switched off. Turn one on in Auto-fill → Sources.")
            return
        }
        phase = .searching
        failures = [:]
        downloadError = nil
        searchTask = Task {
            do {
                let result = try await OnlineTagLookup.searchCovers(artist: artist,
                                                                    album: album,
                                                                    fallbackTerm: fallbackTerm,
                                                                    sources: sources)
                if Task.isCancelled { return }
                covers = result.covers
                failures = result.failures
                phase = .loaded
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                covers = []
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func choose(_ cover: CoverCandidate) {
        guard downloadingID == nil else { return }
        downloadingID = cover.id
        downloadError = nil
        Task {
            do {
                let data = try await OnlineTagLookup.downloadCover(cover)
                downloadingID = nil
                onPick(data)
                dismiss()
            } catch {
                downloadingID = nil
                if !(error is CancellationError) {
                    downloadError = cover.source == .musicbrainz
                        ? "The Cover Art Archive has no cover for that release. Try another."
                        : (error.localizedDescription)
                }
            }
        }
    }
}
