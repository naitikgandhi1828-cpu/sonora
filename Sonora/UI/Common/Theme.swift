//
//  Theme.swift
//  Sonora
//
//  Original colour themes for the player. All values are hand-picked here
//  rather than derived from any third-party design.
//

import SwiftUI
import UIKit

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: Color
    let accentSecondary: Color
    let background: Color
    let surface: Color
    let surfaceElevated: Color
    let textPrimary: Color
    let textSecondary: Color
    let separator: Color
    let isDark: Bool

    var gradient: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: a)
    }

    static let ember = Theme(
        id: "ember", name: "Ember",
        accent: rgb(255, 135, 76), accentSecondary: rgb(233, 69, 96),
        background: rgb(13, 13, 17), surface: rgb(23, 23, 29),
        surfaceElevated: rgb(33, 33, 41),
        textPrimary: rgb(245, 245, 248), textSecondary: rgb(150, 150, 162),
        separator: rgb(48, 48, 58), isDark: true)

    static let midnight = Theme(
        id: "midnight", name: "Midnight",
        accent: rgb(94, 158, 255), accentSecondary: rgb(140, 108, 255),
        background: rgb(10, 12, 20), surface: rgb(19, 22, 34),
        surfaceElevated: rgb(29, 33, 48),
        textPrimary: rgb(238, 242, 252), textSecondary: rgb(138, 148, 172),
        separator: rgb(42, 48, 66), isDark: true)

    static let forest = Theme(
        id: "forest", name: "Forest",
        accent: rgb(76, 217, 148), accentSecondary: rgb(46, 170, 190),
        background: rgb(10, 17, 15), surface: rgb(18, 28, 25),
        surfaceElevated: rgb(27, 40, 36),
        textPrimary: rgb(236, 246, 241), textSecondary: rgb(134, 158, 149),
        separator: rgb(40, 58, 52), isDark: true)

    static let vinyl = Theme(
        id: "vinyl", name: "Vinyl",
        accent: rgb(214, 178, 106), accentSecondary: rgb(178, 122, 74),
        background: rgb(18, 15, 13), surface: rgb(28, 24, 21),
        surfaceElevated: rgb(40, 34, 29),
        textPrimary: rgb(246, 240, 231), textSecondary: rgb(158, 146, 130),
        separator: rgb(56, 48, 41), isDark: true)

    static let neon = Theme(
        id: "neon", name: "Neon",
        accent: rgb(255, 68, 173), accentSecondary: rgb(74, 224, 255),
        background: rgb(9, 8, 16), surface: rgb(19, 17, 32),
        surfaceElevated: rgb(30, 26, 48),
        textPrimary: rgb(244, 240, 255), textSecondary: rgb(146, 138, 176),
        separator: rgb(48, 42, 72), isDark: true)

    static let paper = Theme(
        id: "paper", name: "Paper",
        accent: rgb(200, 82, 54), accentSecondary: rgb(150, 96, 60),
        background: rgb(248, 245, 240), surface: rgb(255, 253, 250),
        surfaceElevated: rgb(240, 235, 227),
        textPrimary: rgb(28, 26, 24), textSecondary: rgb(112, 106, 98),
        separator: rgb(219, 212, 202), isDark: false)

    static let slate = Theme(
        id: "slate", name: "Slate",
        accent: rgb(88, 110, 140), accentSecondary: rgb(120, 148, 176),
        background: rgb(240, 242, 245), surface: rgb(252, 253, 255),
        surfaceElevated: rgb(232, 236, 242),
        textPrimary: rgb(24, 28, 34), textSecondary: rgb(104, 114, 128),
        separator: rgb(212, 218, 226), isDark: false)

    static let all: [Theme] = [ember, midnight, forest, vinyl, neon, paper, slate]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? ember
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    @Published private(set) var theme: Theme
    /// Accent pulled from the current album art when the user enables it.
    @Published var artworkAccent: Color?

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        self.theme = Theme.named(settings.themeID)
    }

    func select(_ theme: Theme) {
        self.theme = theme
        settings.themeID = theme.id
    }

    var accent: Color {
        if settings.useAlbumArtColors, let artworkAccent { return artworkAccent }
        return theme.accent
    }

    func updateArtworkAccent(from image: UIImage?) {
        guard settings.useAlbumArtColors, let image, let average = image.averageColor else {
            artworkAccent = nil
            return
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Push toward something readable on the current background.
        let boosted = UIColor(hue: h,
                              saturation: min(1, max(0.45, s * 1.5)),
                              brightness: theme.isDark ? min(1, max(0.62, b * 1.35))
                                                       : min(0.7, max(0.35, b * 0.8)),
                              alpha: 1)
        artworkAccent = Color(boosted)
    }

    var colorScheme: ColorScheme { theme.isDark ? .dark : .light }
}

// MARK: - Convenience

extension View {
    func cardBackground(_ theme: Theme, radius: CGFloat = 14) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(theme.surface)
        )
    }
}

extension TimeInterval {
    var timecode: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    var longFormat: String {
        guard isFinite, self >= 0 else { return "0m" }
        let total = Int(self.rounded())
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

extension Int64 {
    var byteSize: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: self)
    }
}
