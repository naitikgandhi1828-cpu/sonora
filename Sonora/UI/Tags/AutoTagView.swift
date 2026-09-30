//
//  AutoTagView.swift
//  Sonora
//
//  "Auto-fill from Internet": searches the iTunes catalogue and hands the
//  chosen match (plus its 600px cover) back to the tag editor.
//

import SwiftUI

struct AutoTagView: View {

    let isBatch: Bool
    let onPick: (TagLookupCandidate, Data?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var results: [TagLookupCandidate] = []
    @State private var phase: Phase = .idle
    @State private var applyingID: UUID?
    @State private var searchTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case idle
        case searching
        case loaded
        case failed(String)
    }

    init(initialQuery: String,
         isBatch: Bool,
         onPick: @escaping (TagLookupCandidate, Data?) -> Void) {
        self.isBatch = isBatch
        self.onPick = onPick
        _query = State(initialValue: initialQuery)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Artist and song title", text: $query)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { runSearch() }
                        if phase == .searching {
                            ProgressView()
                        } else {
                            Button("Search") { runSearch() }
                                .disabled(trimmedQuery.isEmpty)
                        }
                    }
                } footer: {
                    Text("Searches Apple's public iTunes catalogue. Only the text above is sent.")
                }

                statusSection

                if !results.isEmpty {
                    Section {
                        ForEach(results) { item in
                            Button { pick(item) } label: { row(item) }
                                .buttonStyle(.plain)
                                .disabled(applyingID != nil)
                        }
                    } header: {
                        Text("Matches")
                    } footer: {
                        Text(isBatch
                             ? "Tapping a match fills in the album details and cover for every selected song."
                             : "Tapping a match fills in the tags and cover. Nothing is saved until you tap Save.")
                    }
                }
            }
            .navigationTitle("Auto-fill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        searchTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if phase == .idle, results.isEmpty, !trimmedQuery.isEmpty { runSearch() }
        }
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .idle:
            if trimmedQuery.isEmpty {
                Section { Text(TagLookupError.emptyQuery.errorDescription ?? "").foregroundStyle(.secondary) }
            }
        case .searching:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching…").foregroundStyle(.secondary)
                }
            }
        case .loaded:
            if results.isEmpty {
                Section { Text(TagLookupError.noResults.errorDescription ?? "").foregroundStyle(.secondary) }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try Again") { runSearch() }
                    .disabled(trimmedQuery.isEmpty)
            }
        }
    }

    private func row(_ item: TagLookupCandidate) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.artworkURL100) { imagePhase in
                if let image = imagePhase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text(item.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detailLine(item))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if applyingID == item.id {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
    }

    private func detailLine(_ item: TagLookupCandidate) -> String {
        var parts: [String] = []
        if !item.album.isEmpty { parts.append(item.album) }
        if let year = item.year { parts.append(String(year)) }
        if !item.genre.isEmpty { parts.append(item.genre) }
        if let n = item.trackNumber {
            parts.append(item.trackCount.map { "Track \(n) of \($0)" } ?? "Track \(n)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func runSearch() {
        let term = trimmedQuery
        searchTask?.cancel()
        guard !term.isEmpty else {
            results = []
            phase = .failed(TagLookupError.emptyQuery.errorDescription ?? "")
            return
        }
        phase = .searching
        searchTask = Task {
            do {
                let found = try await ITunesTagLookup.searchSongs(term: term)
                if Task.isCancelled { return }
                results = found
                phase = .loaded
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                results = []
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func pick(_ item: TagLookupCandidate) {
        guard applyingID == nil else { return }
        applyingID = item.id
        Task {
            var cover: Data?
            if let url = item.artworkURL600 ?? item.artworkURL100 {
                // A missing cover is not worth failing the whole match over.
                cover = try? await ITunesTagLookup.downloadArtwork(url)
            }
            applyingID = nil
            onPick(item, cover)
            dismiss()
        }
    }
}
