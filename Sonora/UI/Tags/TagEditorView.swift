//
//  TagEditorView.swift
//  Sonora
//
//  Edit tags and cover art for one song, or for several at once (an album).
//
//  Single song: every field starts with the song's value.
//  Several songs: a field shows the shared value when all songs agree, and is
//  left empty ("Multiple values") when they don't. Only fields the user
//  actually changes are saved; untouched ones are sent as `nil` (keep).
//

import SwiftUI
import PhotosUI
import UIKit

/// Something to open the editor for. Identifiable so it can drive
/// `.sheet(item:)`, which pins the track IDs at the moment the sheet opens
/// (the playing song may change while the editor is up).
struct TagEditTarget: Identifiable {
    let id = UUID()
    let trackIDs: [UUID]
}

/// The editable fields, in the order the form shows them.
enum TagEditorField: String, CaseIterable, Hashable {
    case title, artist, composer, trackNumber, trackTotal
    case album, albumArtist, genre, year, discNumber
    case comment, lyrics

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .albumArtist: return "Album Artist"
        case .genre: return "Genre"
        case .year: return "Year"
        case .trackNumber: return "Track #"
        case .trackTotal: return "Track Count"
        case .discNumber: return "Disc #"
        case .composer: return "Composer"
        case .comment: return "Comment"
        case .lyrics: return "Lyrics"
        }
    }

    var isNumeric: Bool {
        switch self {
        case .year, .trackNumber, .trackTotal, .discNumber: return true
        default: return false
        }
    }

    /// Fields that normally differ from song to song; batch edits leave
    /// them alone unless the user explicitly unlocks them.
    var isPerSong: Bool {
        self == .title || self == .trackNumber || self == .lyrics
    }

    var maxValue: Int { 9999 }

    func value(of track: Track) -> String {
        switch self {
        case .title: return track.title
        case .artist: return track.artist
        case .album: return track.album
        case .albumArtist: return track.albumArtist
        case .genre: return track.genre
        case .composer: return track.composer
        case .comment: return track.comment
        case .lyrics: return track.lyrics ?? ""
        case .year: return track.year.map(String.init) ?? ""
        case .trackNumber: return track.trackNumber.map(String.init) ?? ""
        case .trackTotal: return track.trackTotal.map(String.init) ?? ""
        case .discNumber: return track.discNumber.map(String.init) ?? ""
        }
    }
}

struct TagEditorView: View {

    let trackIDs: [UUID]

    @EnvironmentObject private var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss

    // Field values, their starting values, and which fields disagree.
    @State private var values: [TagEditorField: String] = [:]
    @State private var originals: [TagEditorField: String] = [:]
    @State private var mixed: Set<TagEditorField> = []
    @State private var didLoad = false
    @State private var editPerSongFields = false

    // Artwork
    @State private var artwork: ArtworkChange = .keep
    @State private var artworkPreview: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var isLoadingCover = false
    @State private var coverMessage: String?

    // Saving
    @State private var writeToFiles = true
    @State private var showAutoTag = false
    @State private var isSaving = false
    @State private var validationMessage: String?
    @State private var summaryTitle = ""
    @State private var summaryMessage: String?

    private var tracks: [Track] { library.tracks(ids: trackIDs) }
    private var isBatch: Bool { Set(trackIDs).count > 1 }

    private var showsPerSongFields: Bool { !isBatch || editPerSongFields }

    var body: some View {
        NavigationStack {
            Form {
                if tracks.isEmpty {
                    Section {
                        Text("These songs are no longer in your library.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    headerSection
                    artworkSection
                    songSection
                    albumSection
                    commentSection
                    if showsPerSongFields { lyricsSection }
                    if isBatch { perSongToggleSection }
                    saveOptionsSection
                }
            }
            .disabled(isSaving)
            .navigationTitle(isBatch ? "Edit \(tracks.count) Songs" : "Edit Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(isSaving || isLoadingCover || tracks.isEmpty)
                }
            }
            .overlay {
                if isSaving { savingOverlay }
            }
            .sheet(isPresented: $showAutoTag) {
                AutoTagView(initialQuery: autoTagQuery, isBatch: isBatch) { candidate, cover in
                    applyLookup(candidate, cover: cover)
                }
            }
            .alert("Check the numbers",
                   isPresented: Binding(get: { validationMessage != nil },
                                        set: { if !$0 { validationMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage ?? "")
            }
        }
        .alert(summaryTitle,
               isPresented: Binding(get: { summaryMessage != nil },
                                    set: { if !$0 { summaryMessage = nil } })) {
            Button("OK") { dismiss() }
        } message: {
            Text(summaryMessage ?? "")
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { loadIfNeeded() }
        .onChange(of: photoItem) { _, item in
            loadPhoto(item)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(isBatch ? "\(tracks.count) songs" : (tracks.first?.fileName ?? ""))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(formatSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                showAutoTag = true
            } label: {
                Label("Auto-fill from Internet", systemImage: "wand.and.stars")
            }
        }
    }

    private var artworkSection: some View {
        Section {
            HStack {
                Spacer()
                coverPreview
                Spacer()
            }
            .listRowBackground(Color.clear)

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                findCoverOnline()
            } label: {
                HStack {
                    Label("Find Cover Online", systemImage: "magnifyingglass")
                    if isLoadingCover {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isLoadingCover)
            if artwork != .remove && (currentArtworkKey != nil || artwork != .keep) {
                Button(role: .destructive) {
                    artwork = .remove
                    artworkPreview = nil
                    coverMessage = nil
                } label: {
                    Label("Remove Cover", systemImage: "trash")
                }
            }
            if artwork != .keep {
                Button {
                    artwork = .keep
                    artworkPreview = nil
                    coverMessage = nil
                } label: {
                    Label("Keep Current Cover", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("Artwork")
        } footer: {
            if let coverMessage {
                Text(coverMessage)
            } else if isBatch {
                Text("A new cover is applied to every selected song.")
            }
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        switch artwork {
        case .replace:
            if let artworkPreview {
                Image(uiImage: artworkPreview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                placeholderCover(text: "New cover")
            }
        case .remove:
            placeholderCover(text: "Cover will be removed")
        case .keep:
            if let key = currentArtworkKey {
                ArtworkView(key: key, size: 160, cornerRadius: 12, useThumbnail: false)
            } else {
                placeholderCover(text: "No cover")
            }
        }
    }

    private func placeholderCover(text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 36, weight: .light))
                Text(text).font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: 160, height: 160)
    }

    private var songSection: some View {
        Section("Song") {
            if showsPerSongFields { textRow(.title) }
            textRow(.artist)
            textRow(.composer)
            trackNumberRow
        }
    }

    private var trackNumberRow: some View {
        HStack(spacing: 8) {
            Text("Track")
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            if showsPerSongFields {
                TextField("#", text: binding(.trackNumber), prompt: Text(mixed.contains(.trackNumber) ? "Mixed" : "#"))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 70)
                Text("of").foregroundStyle(.secondary)
            }
            TextField("Total", text: binding(.trackTotal), prompt: Text(mixed.contains(.trackTotal) ? "Mixed" : "Total"))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 70)
            Spacer(minLength: 0)
        }
    }

    private var albumSection: some View {
        Section("Album") {
            textRow(.album)
            textRow(.albumArtist)
            textRow(.genre)
            textRow(.year, keyboard: .numberPad)
            textRow(.discNumber, keyboard: .numberPad)
        }
    }

    private var commentSection: some View {
        Section("Comment") {
            TextField("Comment",
                      text: binding(.comment),
                      prompt: Text(mixed.contains(.comment) ? "Multiple values — leave empty to keep" : "Comment"),
                      axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private var lyricsSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if (values[.lyrics] ?? "").isEmpty {
                    Text(mixed.contains(.lyrics) ? "Multiple values — leave empty to keep" : "Paste or type lyrics")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: binding(.lyrics))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
            }
        } header: {
            Text("Lyrics")
        }
    }

    private var perSongToggleSection: some View {
        Section {
            Toggle("Edit title, track number & lyrics", isOn: $editPerSongFields)
        } footer: {
            Text("These usually differ from song to song, so they're left as they are unless you turn this on. Fields showing “Multiple values” are kept unless you type something.")
        }
    }

    private var saveOptionsSection: some View {
        Section {
            Toggle("Save into the music file", isOn: $writeToFiles)
                .disabled(writableCount == 0)
        } footer: {
            Text(writeFootnote)
        }
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(writeToFiles && writableCount > 0 ? "Saving into files…" : "Saving…")
                    .font(.subheadline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Rows

    private func textRow(_ field: TagEditorField, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            Text(field.label)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            TextField(field.label,
                      text: binding(field),
                      prompt: Text(mixed.contains(field) ? "Multiple values — leave empty to keep" : field.label))
                .keyboardType(keyboard)
                .textInputAutocapitalization(field.isNumeric ? TextInputAutocapitalization.never : TextInputAutocapitalization.words)
                .autocorrectionDisabled()
        }
    }

    private func binding(_ field: TagEditorField) -> Binding<String> {
        Binding(get: { values[field] ?? "" },
                set: { values[field] = $0 })
    }

    private func isEdited(_ field: TagEditorField) -> Bool {
        (values[field] ?? "") != (originals[field] ?? "")
    }

    // MARK: - Derived text

    private var currentArtworkKey: String? {
        tracks.lazy.compactMap(\.artworkKey).first
    }

    private var writableCount: Int {
        tracks.filter { MediaLibrary.canWriteTags(to: $0) }.count
    }

    private var formatSummary: String {
        let list = tracks
        let formats = Array(Set(list.map { $0.fileExtension.uppercased() })).sorted()
        var parts: [String] = []
        if !formats.isEmpty { parts.append(formats.joined(separator: ", ")) }
        let cueCount = list.filter(\.isCueTrack).count
        if cueCount > 0 { parts.append(cueCount == list.count ? "cue sheet" : "\(cueCount) from cue sheets") }
        return parts.joined(separator: " · ")
    }

    private var writeFootnote: String {
        let list = tracks
        let writable = writableCount
        let general = "MP3, FLAC and M4A files can be updated directly. Other formats and cue-sheet tracks are saved in Sonora only."
        if !isBatch, let track = list.first {
            if writable > 0 {
                return "Sonora writes the tags into the \(track.fileExtension.uppercased()) file itself, so other apps see them too. Turn this off to change them in Sonora only."
            }
            if track.isCueTrack {
                return "This song comes from a cue sheet and shares its file with other songs, so the changes are saved in Sonora only."
            }
            return ".\(track.fileExtension.lowercased()) files can't be tagged by Sonora, so the changes are saved in Sonora only."
        }
        return "\(writable) of \(list.count) selected files support this. " + general
    }

    private var autoTagQuery: String {
        if isBatch {
            let artist = firstNonEmpty(values[.albumArtist], values[.artist])
            let album = values[.album] ?? ""
            return [artist, album]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return ITunesTagLookup.queryTerm(artist: values[.artist] ?? "",
                                         title: values[.title] ?? "",
                                         fileName: tracks.first?.fileName ?? "")
    }

    private func firstNonEmpty(_ candidates: String?...) -> String {
        for c in candidates {
            if let c, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return c }
        }
        return ""
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        let list = tracks
        guard let first = list.first else { return }
        var loaded: [TagEditorField: String] = [:]
        var disagreeing = Set<TagEditorField>()
        for field in TagEditorField.allCases {
            let firstValue = field.value(of: first)
            if list.dropFirst().allSatisfy({ field.value(of: $0) == firstValue }) {
                loaded[field] = firstValue
            } else {
                loaded[field] = ""
                disagreeing.insert(field)
            }
        }
        values = loaded
        originals = loaded
        mixed = disagreeing
        writeToFiles = list.contains { MediaLibrary.canWriteTags(to: $0) }
    }

    // MARK: - Artwork actions

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isLoadingCover = true
        coverMessage = nil
        Task {
            let raw = try? await item.loadTransferable(type: Data.self)
            let jpeg = await ITunesTagLookup.normalizedJPEG(raw)
            isLoadingCover = false
            photoItem = nil     // lets the same photo be picked again
            if let jpeg, let image = UIImage(data: jpeg) {
                setCover(jpeg, preview: image)
            } else {
                coverMessage = "That picture couldn't be loaded."
            }
        }
    }

    private func findCoverOnline() {
        let artist = firstNonEmpty(values[.albumArtist], values[.artist],
                                   tracks.first?.effectiveAlbumArtist)
        let album = firstNonEmpty(values[.album], tracks.first?.album)
        let fallback = autoTagQuery
        isLoadingCover = true
        coverMessage = nil
        Task {
            do {
                let data = try await ITunesTagLookup.findCover(artist: artist,
                                                               album: album,
                                                               fallbackTerm: fallback)
                if let image = UIImage(data: data) {
                    setCover(data, preview: image)
                    coverMessage = "Cover found. Tap Save to keep it."
                } else {
                    coverMessage = TagLookupError.badImage.errorDescription
                }
            } catch {
                if !(error is CancellationError) {
                    coverMessage = error.localizedDescription
                }
            }
            isLoadingCover = false
        }
    }

    private func setCover(_ data: Data, preview: UIImage) {
        artwork = .replace(data)
        artworkPreview = preview
    }

    // MARK: - Auto-fill

    private func applyLookup(_ candidate: TagLookupCandidate, cover: Data?) {
        func fillText(_ field: TagEditorField, _ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values[field] = trimmed }
        }
        func fillNumber(_ field: TagEditorField, _ number: Int?) {
            if let number, number > 0, number <= field.maxValue { values[field] = String(number) }
        }

        if showsPerSongFields {
            fillText(.title, candidate.title)
            fillNumber(.trackNumber, candidate.trackNumber)
        }
        // On a compilation the artists differ per song; don't flatten them.
        if !isBatch || !mixed.contains(.artist) {
            fillText(.artist, candidate.artist)
        }
        fillText(.album, candidate.album)
        fillText(.albumArtist, candidate.albumArtist)
        fillText(.genre, candidate.genre)
        fillNumber(.year, candidate.year)
        fillNumber(.trackTotal, candidate.trackCount)
        fillNumber(.discNumber, candidate.discNumber)

        if let cover, let image = UIImage(data: cover) {
            setCover(cover, preview: image)
            coverMessage = nil
        }
    }

    // MARK: - Saving

    /// The fields the user changed, validated. `nil` (with a message shown)
    /// when a number is invalid.
    private func buildTagSet() -> TagSet? {
        var tags = TagSet()
        for field in TagEditorField.allCases where isEdited(field) {
            if field.isPerSong && !showsPerSongFields { continue }
            let raw = values[field] ?? ""
            if field.isNumeric {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                var number = 0          // empty = clear the field
                if !text.isEmpty {
                    guard let parsed = Int(text), parsed >= 0, parsed <= field.maxValue else {
                        validationMessage = "\(field.label) must be a whole number from 0 to \(field.maxValue)."
                        return nil
                    }
                    number = parsed
                }
                Self.assign(field, number: number, to: &tags)
            } else {
                // Multi-line fields keep their inner formatting.
                let text = (field == .lyrics || field == .comment)
                    ? raw
                    : raw.trimmingCharacters(in: .whitespacesAndNewlines)
                Self.assign(field, text: text, to: &tags)
            }
        }
        return tags
    }

    private static func assign(_ field: TagEditorField, text: String, to tags: inout TagSet) {
        switch field {
        case .title: tags.title = text
        case .artist: tags.artist = text
        case .album: tags.album = text
        case .albumArtist: tags.albumArtist = text
        case .genre: tags.genre = text
        case .composer: tags.composer = text
        case .comment: tags.comment = text
        case .lyrics: tags.lyrics = text
        case .year, .trackNumber, .trackTotal, .discNumber: break
        }
    }

    private static func assign(_ field: TagEditorField, number: Int, to tags: inout TagSet) {
        switch field {
        case .year: tags.year = number
        case .trackNumber: tags.trackNumber = number
        case .trackTotal: tags.trackTotal = number
        case .discNumber: tags.discNumber = number
        default: break
        }
    }

    private func save() {
        guard !isSaving, let tags = buildTagSet() else { return }
        if tags.isEmpty && artwork == .keep {
            dismiss()
            return
        }
        let ids = trackIDs
        let change = artwork
        let write = writeToFiles
        isSaving = true
        Task {
            let result = await library.applyTagEdit(trackIDs: ids,
                                                    tags: tags,
                                                    artwork: change,
                                                    writeToFiles: write)
            isSaving = false
            presentSummary(result)
        }
    }

    private func presentSummary(_ result: TagEditResult) {
        func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }
        func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

        var lines: [String] = []
        if result.written > 0 {
            lines.append("Saved into \(files(result.written)).")
        }
        if result.libraryOnly > 0 {
            lines.append("Saved in Sonora only for \(songs(result.libraryOnly)).")
        }
        if !result.failures.isEmpty {
            lines.append("")
            lines.append("Couldn't update \(files(result.failures.count)):")
            for failure in result.failures.prefix(5) {
                lines.append("• \(failure.0): \(failure.1)")
            }
            if result.failures.count > 5 {
                lines.append("…and \(result.failures.count - 5) more.")
            }
        }
        if lines.isEmpty { lines.append("Nothing needed changing.") }

        if result.failures.isEmpty {
            summaryTitle = "Tags Saved"
            Haptics.success()
        } else {
            summaryTitle = result.written > 0 || result.libraryOnly > 0 ? "Saved with Problems" : "Couldn't Save Into Files"
        }
        summaryMessage = lines.joined(separator: "\n")
    }
}
