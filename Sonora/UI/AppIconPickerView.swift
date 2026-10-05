//
//  AppIconPickerView.swift
//  Sonora
//
//  Settings › App Icon: choose which icon Sonora shows on the Home Screen.
//
//  Every icon comes in a light and a dark version. iOS picks between the two
//  by itself, following the iPhone's appearance, so one choice here covers
//  both. The icon the app ships with is "Chamber"; the others are extra icon
//  sets in the asset catalogue, named "AppIcon-<id>" (they are made from the
//  PNGs in IconSources/ when the app is built).
//
//  The small pictures shown on this screen are separate files,
//  "iconprev-<id>-light.png" and "iconprev-<id>-dark.png", because an app
//  cannot load its own Home Screen icons as ordinary images.
//

import SwiftUI
import UIKit

struct AppIconChoice: Identifiable, Hashable {
    /// "03", "C2" … the same id as in the file names.
    let id: String
    let name: String

    /// The icon the app ships with.
    static let shippedID = "03"

    /// What iOS calls this icon. `nil` means the icon the app ships with.
    var alternateName: String? {
        id == Self.shippedID ? nil : "AppIcon-" + id
    }

    func previewFile(dark: Bool) -> String {
        "iconprev-\(id)-\(dark ? "dark" : "light").png"
    }
}

struct AppIconFamily: Identifiable {
    let id: String
    let title: String
    let choices: [AppIconChoice]

    static let all: [AppIconFamily] = [
        AppIconFamily(id: "chamber", title: "Chamber", choices: [
            AppIconChoice(id: "03", name: "Chamber"),
            AppIconChoice(id: "C1", name: "Double Arch"),
            AppIconChoice(id: "C2", name: "Solid Room"),
            AppIconChoice(id: "C3", name: "Five Bars"),
            AppIconChoice(id: "C4", name: "Note in the Room"),
            AppIconChoice(id: "C5", name: "Doorway Wave"),
            AppIconChoice(id: "C6", name: "Colour Swap")
        ]),
        AppIconFamily(id: "first", title: "First Ideas", choices: [
            AppIconChoice(id: "01", name: "Echo S"),
            AppIconChoice(id: "02", name: "Vinyl"),
            AppIconChoice(id: "04", name: "Ripple"),
            AppIconChoice(id: "05", name: "Pulse Ring"),
            AppIconChoice(id: "06", name: "Layers")
        ]),
        AppIconFamily(id: "more", title: "More Ideas", choices: [
            AppIconChoice(id: "07", name: "Sound Box"),
            AppIconChoice(id: "08", name: "Sunset EQ"),
            AppIconChoice(id: "09", name: "Sunrise"),
            AppIconChoice(id: "10", name: "Dot Wave"),
            AppIconChoice(id: "11", name: "Woofer"),
            AppIconChoice(id: "12", name: "Tonearm")
        ]),
        AppIconFamily(id: "new", title: "New Directions", choices: [
            AppIconChoice(id: "13", name: "Orbit"),
            AppIconChoice(id: "14", name: "Tuning Fork"),
            AppIconChoice(id: "15", name: "Echo Hills"),
            AppIconChoice(id: "16", name: "Music Folder"),
            AppIconChoice(id: "17", name: "Dial"),
            AppIconChoice(id: "18", name: "Headphone Arch")
        ])
    ]
}

struct AppIconPickerView: View {

    @EnvironmentObject private var themes: ThemeManager

    /// The icon in use, as iOS names it (`nil` = the shipped one).
    @State private var currentName: String?
    @State private var isChanging = false
    @State private var problem: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]

    var body: some View {
        let theme = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Each icon is shown in its light and its dark version. You choose once: iOS shows the one that matches your iPhone, and swaps it by itself when the iPhone changes between Light and Dark.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(AppIconFamily.all) { family in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: family.title)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(family.choices) { choice in
                                cell(choice)
                            }
                        }
                    }
                }

                Text("iOS shows a short “You have changed the icon” message each time. That message comes from iOS and cannot be switched off.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 100)
        }
        .background(theme.background.ignoresSafeArea())
        .themedNavBar(theme)
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { currentName = UIApplication.shared.alternateIconName }
        .alert("App Icon",
               isPresented: Binding(get: { problem != nil },
                                    set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func cell(_ choice: AppIconChoice) -> some View {
        let theme = themes.theme
        let isSelected = choice.alternateName == currentName
        return Button {
            choose(choice)
        } label: {
            VStack(spacing: 9) {
                HStack(spacing: 10) {
                    thumbnail(choice, dark: false)
                    thumbnail(choice, dark: true)
                }
                HStack(spacing: 5) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(themes.accent)
                    }
                    Text(choice.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? themes.accent : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isChanging)
        .accessibilityLabel(isSelected ? "\(choice.name), selected" : choice.name)
    }

    @ViewBuilder
    private func thumbnail(_ choice: AppIconChoice, dark: Bool) -> some View {
        // The same corner shape iOS gives icons on the Home Screen.
        let shape = RoundedRectangle(cornerRadius: 13.5, style: .continuous)
        if let image = UIImage(named: choice.previewFile(dark: dark)) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 60, height: 60)
                .clipShape(shape)
                .overlay(shape.stroke(themes.theme.separator, lineWidth: 0.5))
        } else {
            shape
                .fill(themes.theme.surfaceElevated)
                .frame(width: 60, height: 60)
        }
    }

    private func choose(_ choice: AppIconChoice) {
        let name = choice.alternateName
        guard name != currentName, !isChanging else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            problem = "This iPhone doesn't let apps change their icon."
            return
        }
        isChanging = true
        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(name)
                currentName = name
                Haptics.success()
            } catch {
                problem = "iOS couldn't change the icon. \(error.localizedDescription)"
            }
            isChanging = false
        }
    }
}
