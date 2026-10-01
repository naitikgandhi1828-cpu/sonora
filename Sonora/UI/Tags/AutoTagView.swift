//
//  AutoTagView.swift
//  Sonora
//
//  "Auto-fill from Internet": searches the iTunes, Deezer and MusicBrainz
//  catalogues at once and hands the chosen match (plus its cover) back to
//  the tag editor. Each catalogue can be switched off in the Sources menu;
//  one failing or being slow doesn't stop the others' results showing.
//

import SwiftUI

struct AutoTagView: View {

    let isBatch: Bool
    let onPick: (TagLookupCandidate, Data?) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themes: ThemeManager

    @AppStorage(LookupSource.itunes.enabledKey) private var useITunes = true
    @AppStorage(LookupSource.deezer.enabledKey) private var useDeezer = true
    @AppStorage(LookupSource.musicbrainz.enabledKey) private var useMusicBrainz = true
    /// "all" or a LookupSource raw value.
    @AppStorage("lookup.autofill.filter") private var filterRaw = "all"

    @State private var query: String
    private let initialQuery: String
    private let hint: LookupHint?
    @State private var outcome: OnlineTagLookup.SongResults?
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
         hint: LookupHint? = nil,
         onPick: @escaping (TagLookupCandidate, Data?) -> Void) {
        self.isBatch = isBatch
        self.onPick = onPick
        self.initialQuery = initialQuery
        self.hint = (hint?.isEmpty ?? true) ? nil : hint
        _query = State(initialValue: initialQuery)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var enabledSources: [LookupSource] {
        LookupSource.allCases.filter { isOn($0) }
    }

    private func isOn(_ source: LookupSource) -> Bool {
        switch source {
        case .itunes: return useITunes
        case .deezer: return useDeezer
        case .musicbrainz: return useMusicBrainz
        }
    }

    private func toggle(_ source: LookupSource) -> Binding<Bool> {
        Binding(get: { isOn(source) },
                set: { on in
                    switch source {
                    case .itunes: useITunes = on
                    case .deezer: useDeezer = on
                    case .musicbrainz: useMusicBrainz = on
                    }
                })
    }

    /// nil = All.
    private var filter: LookupSource? {
        guard let source = LookupSource(rawValue: filterRaw), isOn(source) else { return nil }
        return source
    }

    private var results: [TagLookupCandidate] {
        outcome?.results(for: filter) ?? []
    }

    var body: some View {
        let theme = themes.theme
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
                                .disabled(trimmedQuery.isEmpty || enabledSources.isEmpty)
                        }
                    }
                } footer: {
                    Text(searchFooter)
                }
                .themedRow(theme)

                if outcome != nil, enabledSources.count > 1 {
                    Section {
                        Picker("Source", selection: $filterRaw) {
                            Text("All").tag("all")
                            ForEach(enabledSources) { source in
                                Text(filterLabel(source)).tag(source.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
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
                    .themedRow(theme)
                }

                if let failures = outcome?.failures, !failures.isEmpty {
                    Section {
                        ForEach(LookupSource.allCases.filter { failures[$0] != nil }) { source in
                            Label("\(source.displayName): \(failures[source] ?? "")",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Not answering")
                    }
                    .themedRow(theme)
                }
            }
            .themedList(theme)
            .navigationTitle("Auto-fill")
            .navigationBarTitleDisplayMode(.inline)
            .themedNavBar(theme)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        searchTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("Search these catalogues") {
                            ForEach(LookupSource.allCases) { source in
                                Toggle(source.displayName, isOn: toggle(source))
                            }
                        }
                    } label: {
                        Label("Sources", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .tint(themes.accent)
        .themedSheet(themes)
        .onAppear {
            if phase == .idle, outcome == nil, !trimmedQuery.isEmpty { runSearch() }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: enabledSources) { _, _ in
            // A source switched on or off: search again so the list matches.
            if outcome != nil || phase == .searching, !trimmedQuery.isEmpty { runSearch() }
        }
    }

    private var searchFooter: String {
        let names = enabledSources.map(\.displayName)
        guard !names.isEmpty else { return "Every catalogue is switched off. Turn one on in Sources." }
        let list = ListFormatter.localizedString(byJoining: names)
        return "Searches \(list). Only the text above is sent."
    }

    private func filterLabel(_ source: LookupSource) -> String {
        let count = outcome?.results(for: source).count ?? 0
        return count > 0 ? "\(source.shortName) \(count)" : source.shortName
    }

    @ViewBuilder
    private var statusSection: some View {
        let theme = themes.theme
        switch phase {
        case .idle:
            if trimmedQuery.isEmpty {
                Section { Text(TagLookupError.emptyQuery.errorDescription ?? "").foregroundStyle(.secondary) }
                    .themedRow(theme)
            }
        case .searching:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching \(enabledSources.count == 1 ? enabledSources[0].displayName : "\(enabledSources.count) catalogues")…")
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow(theme)
        case .loaded:
            if results.isEmpty {
                Section {
                    Text(filter == nil
                         ? (TagLookupError.noResults.errorDescription ?? "")
                         : "\(filter?.displayName ?? "This catalogue") found nothing. Try All.")
                        .foregroundStyle(.secondary)
                }
                .themedRow(theme)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try Again") { runSearch() }
                    .disabled(trimmedQuery.isEmpty)
            }
            .themedRow(theme)
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
                    .foregroundStyle(themes.theme.textPrimary)
                    .lineLimit(2)
                Text(item.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                let detail = detailLine(item)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    SourceBadge(source: item.source, prominent: true)
                    ForEach(item.alsoFoundIn) { other in
                        SourceBadge(source: other, prominent: false)
                    }
                }
                .padding(.top, 2)
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
        if let disc = item.discNumber, disc > 1 { parts.append("Disc \(disc)") }
        if let duration = item.duration, duration > 0 { parts.append(duration.timecode) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func runSearch() {
        let term = trimmedQuery
        searchTask?.cancel()
        guard !term.isEmpty else {
            outcome = nil
            phase = .failed(TagLookupError.emptyQuery.errorDescription ?? "")
            return
        }
        let sources = enabledSources
        guard !sources.isEmpty else {
            outcome = nil
            phase = .failed("Every catalogue is switched off. Turn one on in Sources.")
            return
        }
        // The structured hint only describes the query we opened with.
        let structured = term == initialQuery.trimmingCharacters(in: .whitespacesAndNewlines) ? hint : nil
        phase = .searching
        searchTask = Task {
            do {
                let found = try await OnlineTagLookup.searchSongs(term: term, hint: structured, sources: sources)
                if Task.isCancelled { return }
                outcome = found
                phase = .loaded
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                outcome = nil
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func pick(_ item: TagLookupCandidate) {
        guard applyingID == nil else { return }
        applyingID = item.id
        Task {
            // Deezer needs a second request for track/disc numbers and genre.
            let full = await OnlineTagLookup.enrich(item)
            // A missing cover is not worth failing the whole match over.
            let cover = await OnlineTagLookup.downloadCover(for: full)
            applyingID = nil
            onPick(full, cover)
            dismiss()
        }
    }
}

/// Small capsule naming the catalogue a result came from.
struct SourceBadge: View {
    let source: LookupSource
    var prominent: Bool = true

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        Text(source.shortName)
            .font(.system(size: 9, weight: .bold))
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(prominent ? themes.accent : Color.secondary)
            .background(
                Capsule().fill((prominent ? themes.accent : Color.secondary).opacity(0.15))
            )
            .accessibilityLabel("From \(source.displayName)")
    }
}
