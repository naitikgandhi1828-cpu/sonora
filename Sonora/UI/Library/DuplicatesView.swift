//
//  DuplicatesView.swift
//  Sonora
//
//  Everything the user sees about duplicate songs:
//
//    • DuplicateReviewView   — "Are these the same song?", one pair at a
//                              time, for the pairs Sonora is not sure about.
//    • DuplicateSettingsView — the switch, the list of merged songs (with a
//                              way to separate them) and the remembered
//                              answers.
//    • DuplicateBanner       — the small card on the Library screen that
//                              says there is something to review.
//
//  Merging never deletes a file; the copy that is not shown is only hidden.
//

import SwiftUI

// MARK: - One copy of a song

/// A compact description of one file, so two copies can be told apart.
private struct SongCopyCard: View {
    let track: Track
    var note: String?
    var onListen: (() -> Void)?

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager

    private var whereItIs: String {
        var parts: [String] = []
        if let rootID = track.rootID, let root = library.roots.first(where: { $0.id == rootID }) {
            parts.append(root.displayName)
        } else {
            parts.append("Imported Files")
        }
        if !track.relativeFolder.isEmpty { parts.append(track.relativeFolder) }
        return parts.joined(separator: " › ")
    }

    private var facts: String {
        var parts = [track.duration.timecode, track.qualityBadge]
        if track.fileSize > 0 { parts.append(track.fileSize.byteSize) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let theme = themes.theme
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(key: track.artworkKey, size: 54, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("\(track.displayArtist) — \(track.displayAlbum)")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Text(facts)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                Text(whereItIs)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary.opacity(0.8))
                    .lineLimit(2)
                Text(track.fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    Text(note)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(themes.accent)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
            if let onListen {
                Button(action: onListen) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(themes.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Listen")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(theme)
    }
}

// MARK: - Review

struct DuplicateReviewView: View {

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var themes: ThemeManager

    /// Pairs put aside with "Decide Later" while this sheet is open.
    @State private var putAside = Set<String>()
    @State private var forSimilar = false

    private var waiting: [DuplicateQuestion] {
        library.duplicateQuestions.filter { !putAside.contains($0.id) }
    }

    var body: some View {
        let theme = themes.theme
        let questions = waiting
        NavigationStack {
            Group {
                if let question = questions.first,
                   let first = library.track(id: question.first),
                   let second = library.track(id: question.second) {
                    ScrollView {
                        ask(question, first, second, left: questions.count)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .padding(.bottom, 30)
                    }
                } else {
                    finished
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .themedNavBar(theme)
            .navigationTitle("Possible Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.tint(themes.accent)
                }
            }
        }
    }

    private func ask(_ question: DuplicateQuestion, _ first: Track, _ second: Track, left: Int) -> some View {
        let theme = themes.theme
        let firstIsBetter = DuplicateFinder.isBetter(first, than: second)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Are these the same song?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text(question.doubt.headline + ". " + question.doubt.explanation)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if left > 1 {
                    Text("\(left) to review")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(themes.accent)
                }
            }

            SongCopyCard(track: first,
                         note: firstIsBetter ? "Better quality — this one is kept if you merge" : nil,
                         onListen: { listen([first.id, second.id], start: 0) })
            SongCopyCard(track: second,
                         note: firstIsBetter ? nil : "Better quality — this one is kept if you merge",
                         onListen: { listen([first.id, second.id], start: 1) })

            Toggle(isOn: $forSimilar) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remember for similar songs")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                    Text("Give the same answer, without asking, for all \(question.doubt.similarCases).")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(themes.accent)
            .padding(12)
            .cardBackground(theme)

            VStack(spacing: 10) {
                Button {
                    answer(question, .merge)
                } label: {
                    Label("Same Song — Merge", systemImage: "arrow.triangle.merge")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(themes.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(themes.accent.isLight ? Color.black : Color.white)
                }
                .buttonStyle(.plain)

                Button {
                    answer(question, .separate)
                } label: {
                    Label("Different Songs — Keep Both", systemImage: "square.split.2x1")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(themes.accent.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(themes.accent)
                }
                .buttonStyle(.plain)

                Button("Decide Later") {
                    putAside.insert(question.id)
                    forSimilar = false
                }
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
                .padding(.top, 2)
            }

            Text("Merging never deletes a file. Sonora shows the song once, plays the better-quality copy and hides the other. Your answer is remembered, and you can separate merged songs again in Settings › Duplicate Songs.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finished: some View {
        let theme = themes.theme
        let laterCount = library.duplicateQuestions.count
        return VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(themes.accent)
            Text(laterCount == 0 ? "Nothing left to review" : "\(laterCount) left for later")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(laterCount == 0
                 ? "Sonora will ask again only when it finds a new pair it is not sure about."
                 : "You can come back to them from the Library screen or Settings › Duplicate Songs.")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(themes.accent)
                .padding(.top, 6)
        }
        .padding(30)
    }

    private func answer(_ question: DuplicateQuestion, _ answer: DuplicateAnswer) {
        library.answerDuplicate(question, answer, forSimilar: forSimilar)
        forSimilar = false
        Haptics.select()
    }

    private func listen(_ ids: [UUID], start: Int) {
        player.play(trackIDs: ids, startIndex: start, sourceName: "Possible Duplicates")
        Haptics.tap()
    }
}

// MARK: - Settings

struct DuplicateSettingsView: View {

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager

    @State private var showReview = false
    @State private var confirmForget = false

    private struct RememberedRule: Identifiable {
        let doubt: DuplicateDoubt
        let answer: DuplicateAnswer
        var id: String { doubt.rawValue }
    }

    private var rememberedRules: [RememberedRule] {
        DuplicateDoubt.allCases.compactMap { doubt in
            library.duplicateMemory.rules[doubt.rawValue].map { RememberedRule(doubt: doubt, answer: $0) }
        }
    }

    var body: some View {
        let theme = themes.theme
        List {
            Section {
                Toggle("Merge duplicate songs",
                       isOn: Binding(get: { library.duplicateMemory.enabled },
                                     set: { library.setMergeDuplicates($0) }))
            } footer: {
                Text("When the same song is in your library more than once, Sonora shows it once and plays the best-quality copy. No file is deleted. When Sonora is not sure two songs are the same, it asks you and remembers the answer.")
            }
            .themedRow(theme)

            if library.duplicateMemory.enabled {
                reviewSection
                mergedSection
                rememberedSection
            }
        }
        .themedList(theme)
        .themedNavBar(theme)
        .tint(themes.accent)
        .navigationTitle("Duplicate Songs")
        .navigationBarTitleDisplayMode(.inline)
        // Room for the mini player, which floats over the bottom of the screen.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 60) }
        .sheet(isPresented: $showReview) {
            DuplicateReviewView().themedSheet(themes)
        }
        .confirmationDialog("Forget every remembered answer?",
                            isPresented: $confirmForget,
                            titleVisibility: .visible) {
            Button("Forget Answers", role: .destructive) { library.forgetDuplicateAnswers() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clear duplicates stay merged. Every pair Sonora was not sure about will be asked again, including the ones you separated.")
        }
    }

    private var reviewSection: some View {
        let count = library.duplicateQuestions.count
        return Section {
            if count == 0 {
                Label("Nothing to review", systemImage: "checkmark.circle")
                    .foregroundStyle(themes.theme.textSecondary)
            } else {
                Button {
                    showReview = true
                } label: {
                    Label("Review \(count) possible duplicate\(count == 1 ? "" : "s")",
                          systemImage: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        } header: {
            Text("Not Sure")
        }
        .themedRow(themes.theme)
    }

    private var mergedSection: some View {
        let groups = library.mergedGroups
        return Section {
            if groups.isEmpty {
                Text("No duplicates found.")
                    .foregroundStyle(themes.theme.textSecondary)
            } else {
                ForEach(groups) { group in
                    if let keeper = library.track(id: group.keeper) {
                        MergedGroupRow(keeper: keeper, copyIDs: group.copies)
                    }
                }
            }
        } header: {
            Text(groups.isEmpty ? "Merged Songs" : "Merged Songs (\(groups.count))")
        } footer: {
            if !groups.isEmpty {
                Text("Tap a song to see its hidden copies. “Separate” shows a copy as its own song again; Sonora remembers that and will not merge it back.")
            }
        }
        .themedRow(themes.theme)
    }

    private var rememberedSection: some View {
        let rules = rememberedRules
        let pairs = library.duplicateMemory.pairs.count
        return Section {
            if rules.isEmpty && pairs == 0 {
                Text("No answers remembered yet.")
                    .foregroundStyle(themes.theme.textSecondary)
            }
            ForEach(rules) { rule in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.answer == .merge ? "Always merge" : "Always keep both")
                            .font(.system(size: 15))
                            .foregroundStyle(themes.theme.textPrimary)
                        Text(rule.doubt.similarCases)
                            .font(.system(size: 12))
                            .foregroundStyle(themes.theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Button("Forget") { library.forgetDuplicateRule(rule.doubt) }
                        .font(.system(size: 13))
                        .buttonStyle(.borderless)
                }
            }
            if pairs > 0 {
                HStack {
                    Text("Answers about single pairs")
                        .foregroundStyle(themes.theme.textPrimary)
                    Spacer()
                    Text("\(pairs)").foregroundStyle(themes.theme.textSecondary)
                }
            }
            if !rules.isEmpty || pairs > 0 {
                Button("Forget All Answers", role: .destructive) { confirmForget = true }
            }
        } header: {
            Text("Remembered")
        } footer: {
            Text("Answers are remembered by title, artist, album and length, so they still apply after a rescan or when a song is downloaded again.")
        }
        .themedRow(themes.theme)
    }
}

/// A merged song and, when opened, the copies hidden behind it.
private struct MergedGroupRow: View {
    let keeper: Track
    let copyIDs: [UUID]

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager
    @State private var isOpen = false

    var body: some View {
        let theme = themes.theme
        DisclosureGroup(isExpanded: $isOpen) {
            copyLine(keeper, label: "Shown in the library", canSeparate: false)
            ForEach(copyIDs, id: \.self) { id in
                if let copy = library.track(id: id) {
                    copyLine(copy, label: "Hidden copy", canSeparate: true)
                }
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(key: keeper.artworkKey, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(keeper.displayTitle)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text("\(keeper.displayArtist) · \(copyIDs.count + 1) copies")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func copyLine(_ track: Track, label: String, canSeparate: Bool) -> some View {
        let theme = themes.theme
        var place = "Imported Files"
        if let rootID = track.rootID, let root = library.roots.first(where: { $0.id == rootID }) {
            place = root.displayName
        }
        if !track.relativeFolder.isEmpty { place += " › " + track.relativeFolder }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canSeparate ? theme.textSecondary : themes.accent)
                Text(track.fileName)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(track.displayAlbum) · \(track.duration.timecode) · \(track.qualityBadge)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Text(place)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if canSeparate {
                Button("Separate") {
                    library.separateMergedCopy(track.id)
                    Haptics.select()
                }
                .font(.system(size: 13))
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Library banner

/// Shown on the Library screen while there are pairs to review.
struct DuplicateBanner: View {
    let count: Int
    let action: () -> Void

    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        let theme = themes.theme
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 20))
                    .foregroundStyle(themes.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 song may be a duplicate" : "\(count) songs may be duplicates")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Sonora is not sure. Tap to decide.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary.opacity(0.6))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(theme)
        }
        .buttonStyle(.plain)
    }
}
