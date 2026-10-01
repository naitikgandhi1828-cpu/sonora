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

    // MARK: More dark themes

    static let ocean = Theme(
        id: "ocean", name: "Ocean",
        accent: rgb(38, 198, 218), accentSecondary: rgb(41, 121, 255),
        background: rgb(7, 16, 22), surface: rgb(13, 27, 36),
        surfaceElevated: rgb(21, 39, 51),
        textPrimary: rgb(232, 246, 250), textSecondary: rgb(128, 156, 168),
        separator: rgb(34, 56, 70), isDark: true)

    static let sunset = Theme(
        id: "sunset", name: "Sunset",
        accent: rgb(255, 112, 67), accentSecondary: rgb(171, 71, 188),
        background: rgb(20, 11, 18), surface: rgb(32, 19, 29),
        surfaceElevated: rgb(45, 28, 41),
        textPrimary: rgb(252, 240, 244), textSecondary: rgb(170, 140, 155),
        separator: rgb(62, 40, 55), isDark: true)

    static let crimson = Theme(
        id: "crimson", name: "Crimson",
        accent: rgb(239, 58, 72), accentSecondary: rgb(176, 30, 66),
        background: rgb(14, 9, 10), surface: rgb(26, 17, 19),
        surfaceElevated: rgb(38, 25, 28),
        textPrimary: rgb(248, 238, 239), textSecondary: rgb(160, 136, 140),
        separator: rgb(56, 38, 42), isDark: true)

    static let aurora = Theme(
        id: "aurora", name: "Aurora",
        accent: rgb(102, 230, 170), accentSecondary: rgb(150, 110, 255),
        background: rgb(8, 12, 20), surface: rgb(16, 22, 34),
        surfaceElevated: rgb(25, 33, 49),
        textPrimary: rgb(236, 244, 250), textSecondary: rgb(134, 150, 170),
        separator: rgb(38, 48, 68), isDark: true)

    static let lavender = Theme(
        id: "lavender", name: "Lavender",
        accent: rgb(178, 140, 255), accentSecondary: rgb(255, 128, 200),
        background: rgb(15, 11, 22), surface: rgb(25, 20, 36),
        surfaceElevated: rgb(36, 29, 51),
        textPrimary: rgb(244, 238, 252), textSecondary: rgb(152, 140, 176),
        separator: rgb(52, 43, 72), isDark: true)

    static let gold = Theme(
        id: "gold", name: "Gold",
        accent: rgb(232, 190, 92), accentSecondary: rgb(196, 140, 52),
        background: rgb(8, 8, 8), surface: rgb(20, 19, 17),
        surfaceElevated: rgb(31, 29, 25),
        textPrimary: rgb(246, 242, 232), textSecondary: rgb(156, 148, 130),
        separator: rgb(48, 45, 38), isDark: true)

    static let coffee = Theme(
        id: "coffee", name: "Coffee",
        accent: rgb(200, 145, 100), accentSecondary: rgb(150, 95, 65),
        background: rgb(22, 16, 13), surface: rgb(33, 25, 21),
        surfaceElevated: rgb(46, 35, 29),
        textPrimary: rgb(245, 236, 228), textSecondary: rgb(164, 146, 132),
        separator: rgb(64, 50, 42), isDark: true)

    /// Pure black background: easiest on battery with an OLED screen.
    static let oled = Theme(
        id: "oled", name: "OLED Black",
        accent: rgb(10, 132, 255), accentSecondary: rgb(94, 92, 230),
        background: rgb(0, 0, 0), surface: rgb(14, 14, 16),
        surfaceElevated: rgb(24, 24, 27),
        textPrimary: rgb(255, 255, 255), textSecondary: rgb(142, 142, 150),
        separator: rgb(38, 38, 42), isDark: true)

    // MARK: More light themes

    static let sakura = Theme(
        id: "sakura", name: "Sakura",
        accent: rgb(214, 70, 128), accentSecondary: rgb(236, 120, 150),
        background: rgb(253, 244, 247), surface: rgb(255, 251, 252),
        surfaceElevated: rgb(246, 232, 238),
        textPrimary: rgb(40, 22, 30), textSecondary: rgb(128, 98, 110),
        separator: rgb(236, 214, 223), isDark: false)

    static let mint = Theme(
        id: "mint", name: "Mint",
        accent: rgb(0, 150, 120), accentSecondary: rgb(40, 170, 180),
        background: rgb(240, 249, 246), surface: rgb(251, 255, 253),
        surfaceElevated: rgb(226, 241, 236),
        textPrimary: rgb(18, 36, 31), textSecondary: rgb(92, 118, 110),
        separator: rgb(204, 226, 219), isDark: false)

    static let sky = Theme(
        id: "sky", name: "Sky",
        accent: rgb(30, 120, 220), accentSecondary: rgb(80, 170, 240),
        background: rgb(240, 246, 253), surface: rgb(252, 254, 255),
        surfaceElevated: rgb(226, 236, 248),
        textPrimary: rgb(18, 28, 44), textSecondary: rgb(96, 112, 136),
        separator: rgb(206, 220, 238), isDark: false)

    static let sand = Theme(
        id: "sand", name: "Sand",
        accent: rgb(176, 120, 40), accentSecondary: rgb(200, 150, 80),
        background: rgb(247, 241, 228), surface: rgb(253, 250, 242),
        surfaceElevated: rgb(238, 229, 210),
        textPrimary: rgb(40, 32, 20), textSecondary: rgb(120, 108, 88),
        separator: rgb(224, 212, 188), isDark: false)

    static let all: [Theme] = [ember, midnight, forest, vinyl, neon,
                               ocean, sunset, crimson, aurora, lavender, gold, coffee, oled,
                               paper, slate, sakura, mint, sky, sand]

    static var dark: [Theme] { all.filter { $0.isDark } }
    static var light: [Theme] { all.filter { !$0.isDark } }

    /// The same theme with its accent swapped for a colour the user picked.
    func withAccent(_ color: Color) -> Theme {
        // A second accent a little darker/lighter than the first keeps the
        // gradients from going flat.
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let second = Color(UIColor(hue: (h + 0.06).truncatingRemainder(dividingBy: 1),
                                   saturation: s, brightness: max(0.25, b * 0.82), alpha: 1))
        return Theme(id: id, name: name, accent: color, accentSecondary: second,
                     background: background, surface: surface, surfaceElevated: surfaceElevated,
                     textPrimary: textPrimary, textSecondary: textSecondary,
                     separator: separator, isDark: isDark)
    }

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
        self.theme = Self.resolve(themeID: settings.themeID, accentHex: settings.customAccentHex)
    }

    /// The theme as picked, before any custom accent is applied.
    var baseTheme: Theme { Theme.named(settings.themeID) }

    func select(_ theme: Theme) {
        settings.themeID = theme.id
        self.theme = Self.resolve(themeID: theme.id, accentHex: settings.customAccentHex)
    }

    /// Custom accent colour, or nil for the theme's own.
    var customAccent: Color? {
        Color(hex: settings.customAccentHex)
    }

    func setCustomAccent(_ color: Color?) {
        settings.customAccentHex = color?.hexString ?? ""
        theme = Self.resolve(themeID: settings.themeID, accentHex: settings.customAccentHex)
    }

    private static func resolve(themeID: String, accentHex: String) -> Theme {
        let base = Theme.named(themeID)
        guard let custom = Color(hex: accentHex) else { return base }
        return base.withAccent(custom)
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

extension Color {
    /// "#RRGGBB" -> Color. Empty or malformed strings give nil.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self = Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255,
                     opacity: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

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
        // The upper bound matters too: `Int(1e300)` traps just like `Int(.nan)`,
        // and `.greatestFiniteMagnitude` is used as "no end" elsewhere.
        guard isFinite, self >= 0, self < 1e9 else { return "0:00" }
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    var longFormat: String {
        guard isFinite, self >= 0, self < 1e12 else { return "0m" }
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
