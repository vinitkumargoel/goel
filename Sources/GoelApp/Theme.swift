import SwiftUI
import AppKit

enum Theme {
    static var accent:      Color { ThemePalette.color(\.accent) }
    static var accentPress: Color { ThemePalette.color(\.accentPress) }
    static var green:       Color { ThemePalette.color(\.green) }
    static var orange:      Color { ThemePalette.color(\.orange) }
    static var red:         Color { ThemePalette.color(\.red) }
    static var purple:      Color { ThemePalette.color(\.purple) }
    static var teal:        Color { ThemePalette.color(\.teal) }
    static var indigo:      Color { ThemePalette.color(\.indigo) }

    static var windowTint: Color? { ThemePalette.current.windowTint }

    /// Do not hard-code white: it measures 2.0–2.4:1 on the dark themes; per-fill picking clears 5.9:1.
    static var onAccent: Color { ThemePalette.ink(on: \.accent) }

    static var onIndigo: Color { ThemePalette.ink(on: \.indigo) }

    static var onRed: Color { ThemePalette.ink(on: \.red) }

    /// 0.85 is the lowest opacity at which all four themes still clear 4.5:1.
    static var onAccentSecondary: Color { onAccent.opacity(0.85) }

    static var onIndigoSecondary: Color { onIndigo.opacity(0.85) }

    static let rowAlt = Color.primary.opacity(0.03)
    static let hairline = Color.primary.opacity(0.10)
}

struct ThemeColors {
    struct Pair { let light: UInt32; let dark: UInt32 }
    let accent, accentPress, green, orange, red, yellow, purple, teal, indigo: Pair
}

enum ThemePalette {
    /// `nonisolated(unsafe)`: non-isolated view code reads this, so writes must stay on the main thread.
    nonisolated(unsafe) static var current: AppTheme = .frostDark

    static func color(_ key: KeyPath<ThemeColors, ThemeColors.Pair>) -> Color {
        current.resolvedColor(key)
    }

    static func ink(on key: KeyPath<ThemeColors, ThemeColors.Pair>) -> Color {
        let pair = current.colors[keyPath: key]
        return Color.adaptive(light: WCAG.ink(on: pair.light),
                              dark: WCAG.ink(on: pair.dark))
    }
}

enum WCAG {

    private static let lightInk: UInt32 = 0xFFFFFF
    private static let darkInk:  UInt32 = 0x0E1116

    /// Constants are fixed by WCAG 2.1 §1.4.3 — do not round them.
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
             + 0.7152 * channel((hex >> 8) & 0xFF)
             + 0.0722 * channel(hex & 0xFF)
    }

    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func ink(on fill: UInt32) -> UInt32 {
        contrastRatio(lightInk, fill) >= contrastRatio(darkInk, fill) ? lightInk : darkInk
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// sRGB, not the calibrated space: anything else shifts the audited palette values.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

enum FileType: String, CaseIterable, Hashable {
    case iso, video, archive, app, magnet, doc

    var symbol: String {
        switch self {
        case .iso: return "opticaldisc"
        case .video: return "film"
        case .archive: return "doc.zipper"
        case .app: return "app.badge"
        case .magnet: return "link"
        case .doc: return "doc"
        }
    }

    var gradient: [Color] {
        switch self {
        case .iso: return [Color(hex: 0xFF9F0A), Color(hex: 0xFF6A00)]
        case .video: return [Color(hex: 0xBF5AF2), Color(hex: 0x8A3FFC)]
        case .archive: return [Color(hex: 0x64D2FF), Color(hex: 0x0A84FF)]
        case .app: return [Color(hex: 0x32D74B), Color(hex: 0x1A9E3A)]
        case .magnet: return [Color(hex: 0xFF453A), Color(hex: 0xC91D12)]
        case .doc: return [Color(hex: 0x8E8E93), Color(hex: 0x636366)]
        }
    }
}

enum DetailPanelPosition: String, CaseIterable, Identifiable {
    case right = "Right"
    case bottom = "Bottom"
    var id: String { rawValue }

    var settingsValue: String { rawValue.lowercased() }

    init(settingsValue: String) {
        self = DetailPanelPosition.allCases.first { $0.settingsValue == settingsValue } ?? .right
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case frostLight = "Frost Light"
    case frostDark = "Frost Dark"
    case dracula = "Dracula"
    case nord = "Nord"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .frostLight: return .light
        default: return .dark
        }
    }

    var colors: ThemeColors {
        switch self {
        case .frostLight:
            // Deliberately darker than the mockup: as drawn, green/orange/yellow fell under AA (3.76–4.38:1).
            return ThemeColors(
                accent:      .init(light: 0x3F58D6, dark: 0x5B7CFA),
                accentPress: .init(light: 0x2E45B8, dark: 0x4F6EF0),
                green:       .init(light: 0x137B36, dark: 0x2FBF5B),
                orange:      .init(light: 0xA55600, dark: 0xE08A1E),
                red:         .init(light: 0xCE0E0E, dark: 0xE24B4B),
                yellow:      .init(light: 0x836800, dark: 0xD1A93A),
                purple:      .init(light: 0x7A3FD0, dark: 0x9B6FE8),
                teal:        .init(light: 0x0E7490, dark: 0x27AEC7),
                indigo:      .init(light: 0x3F58D6, dark: 0x8AA2FF))
        case .frostDark:
            return ThemeColors(
                accent:      .init(light: 0x4F6EF0, dark: 0x8AA2FF),
                accentPress: .init(light: 0x3F58D6, dark: 0x738FF5),
                green:       .init(light: 0x158A3C, dark: 0x4ADE80),
                orange:      .init(light: 0xA85800, dark: 0xFBBF6B),
                red:         .init(light: 0xCE0E0E, dark: 0xF87171),
                yellow:      .init(light: 0x8A6D00, dark: 0xFCD34D),
                purple:      .init(light: 0x7A3FD0, dark: 0xC0A2FB),
                teal:        .init(light: 0x0E7490, dark: 0x7FDBE8),
                indigo:      .init(light: 0x3F58D6, dark: 0xA5B8FF))
        case .dracula:
            return ThemeColors(
                accent:      .init(light: 0x8B5CF6, dark: 0xBD93F9),
                accentPress: .init(light: 0x7C3AED, dark: 0xA97BF0),
                green:       .init(light: 0x2FBF5B, dark: 0x50FA7B),
                orange:      .init(light: 0xE08A1E, dark: 0xFFB86C),
                red:         .init(light: 0xE24B4B, dark: 0xFF6E6E),
                yellow:      .init(light: 0xD1A93A, dark: 0xF1FA8C),
                purple:      .init(light: 0xB86FD8, dark: 0xFF79C6),
                teal:        .init(light: 0x2AB7CE, dark: 0x8BE9FD),
                indigo:      .init(light: 0x8B5CF6, dark: 0xBD93F9))
        case .nord:
            // Aurora orange and purple are lifted off official Nord: as published they miss AA (4.39/4.41:1).
            return ThemeColors(
                accent:      .init(light: 0x5E81AC, dark: 0x88C0D0),
                accentPress: .init(light: 0x4C6E96, dark: 0x81A1C1),
                green:       .init(light: 0x6E9A5A, dark: 0xA3BE8C),
                orange:      .init(light: 0xC1794A, dark: 0xD48B74),
                red:         .init(light: 0xBF616A, dark: 0xE08691),
                yellow:      .init(light: 0xA88A3E, dark: 0xEBCB8B),
                purple:      .init(light: 0x8A6BB0, dark: 0xB892B1),
                teal:        .init(light: 0x3B8A93, dark: 0x8FBCBB),
                indigo:      .init(light: 0x5E81AC, dark: 0x81A1C1))
        }
    }

    var windowTint: Color? {
        switch self {
        case .frostLight, .frostDark: return nil
        case .dracula: return Color(hex: 0x282A36)
        case .nord:    return Color(hex: 0x2E3440)
        }
    }

    func resolvedColor(_ key: KeyPath<ThemeColors, ThemeColors.Pair>) -> Color {
        let pair = colors[keyPath: key]
        return Color.adaptive(light: pair.light, dark: pair.dark)
    }

    var settingsValue: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The legacy "system"/"light"/"dark" cases must stay, or existing installs reset their theme.
    init(settingsValue: String) {
        switch settingsValue {
        case "light": self = .frostLight
        case "dark", "system": self = .frostDark
        default:
            self = AppTheme.allCases.first { $0.settingsValue == settingsValue } ?? .frostDark
        }
    }
}
