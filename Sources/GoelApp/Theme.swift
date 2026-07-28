import SwiftUI
import AppKit

/// The semantic palette (accent, status colors, badges). Colors resolve against the selected
/// named theme, each backed by a dynamic `NSColor` so it also tracks the theme's base appearance.
enum Theme {
    static var accent:      Color { ThemePalette.color(\.accent) }
    static var accentPress: Color { ThemePalette.color(\.accentPress) }
    static var green:       Color { ThemePalette.color(\.green) }
    static var orange:      Color { ThemePalette.color(\.orange) }
    static var red:         Color { ThemePalette.color(\.red) }
    static var purple:      Color { ThemePalette.color(\.purple) }
    static var teal:        Color { ThemePalette.color(\.teal) }
    static var indigo:      Color { ThemePalette.color(\.indigo) }

    /// An optional wash tint over the window canvas so themes with a non-neutral background read as
    /// that colour despite system materials. nil for the Frost themes.
    static var windowTint: Color? { ThemePalette.current.windowTint }

    // MARK: Legible ink on filled chips

    /// The text colour to use on top of a solid ``accent`` fill. Hard-coded white measured 2.0–2.4:1
    /// on the three dark themes; picking per fill takes all four to 5.9:1 or better.
    static var onAccent: Color { ThemePalette.ink(on: \.accent) }

    /// As ``onAccent``, for the ``indigo`` fill used by selected server rows.
    static var onIndigo: Color { ThemePalette.ink(on: \.indigo) }

    /// As ``onAccent``, for the ``red`` fill behind a destructive confirm button. White on the dark
    /// themes' red measured 2.63–2.77:1 — the one label you least want misread.
    static var onRed: Color { ThemePalette.ink(on: \.red) }

    /// The de-emphasised ink for a filled row's second line. `white.opacity(0.6…0.75)` measured as
    /// low as 3.75:1; 0.85 is the lowest opacity at which all four themes clear 4.5:1.
    static var onAccentSecondary: Color { onAccent.opacity(0.85) }

    /// As ``onAccentSecondary``, over the ``indigo`` fill.
    static var onIndigoSecondary: Color { onIndigo.opacity(0.85) }

    /// Subtle alternating-row tint.
    static let rowAlt = Color.primary.opacity(0.03)
    static let hairline = Color.primary.opacity(0.10)
}

/// The full set of semantic colors for one named theme as `light`/`dark` hex pairs. Only one is
/// normally used, but keeping both keeps a value legible under the opposite appearance.
struct ThemeColors {
    struct Pair { let light: UInt32; let dark: UInt32 }
    let accent, accentPress, green, orange, red, yellow, purple, teal, indigo: Pair
}

/// Holds the active theme and resolves ``ThemeColors`` into SwiftUI `Color`s bound to its base
/// appearance. Read on the main thread during view updates; set when the persisted theme changes.
enum ThemePalette {
    /// The active theme (defaults to Frost Dark). `nonisolated(unsafe)` because view code that isn't
    /// main-actor isolated reads it, while writes only ever happen on the main thread.
    nonisolated(unsafe) static var current: AppTheme = .frostDark

    static func color(_ key: KeyPath<ThemeColors, ThemeColors.Pair>) -> Color {
        current.resolvedColor(key)
    }

    /// The ink — white or near-black — that contrasts better against one semantic colour used as a
    /// solid fill. Resolved per appearance so it flips in lockstep with the dynamic fill.
    static func ink(on key: KeyPath<ThemeColors, ThemeColors.Pair>) -> Color {
        let pair = current.colors[keyPath: key]
        return Color.adaptive(light: WCAG.ink(on: pair.light),
                              dark: WCAG.ink(on: pair.dark))
    }
}

/// Contrast arithmetic from WCAG 2.1 §1.4.3, used to *choose* colours at runtime: with four
/// themes, a hard-coded ink gets at least one wrong, and deriving it keeps future themes legible.
enum WCAG {

    /// The two inks the app picks between. Pure black is avoided: it reads as a
    /// hole punched in a coloured chip, and #0E1116 is within 0.05:1 of it.
    private static let lightInk: UInt32 = 0xFFFFFF
    private static let darkInk:  UInt32 = 0x0E1116

    /// Relative luminance of an `0xRRGGBB` value, per WCAG 2.1.
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
             + 0.7152 * channel((hex >> 8) & 0xFF)
             + 0.0722 * channel(hex & 0xFF)
    }

    /// The WCAG contrast ratio between two `0xRRGGBB` values, 1…21.
    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Whichever of the two inks contrasts better against `fill`.
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

    /// A color resolving to `light` under Aqua and `dark` under Dark Aqua, tracking the window's
    /// effective appearance. Backed by a dynamic `NSColor`, so no per-view `@Environment` reads.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// `0xRRGGBB` convenience matching `Color(hex:)`, in the sRGB space so the
    /// adaptive palette renders the exact audited values.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// The visual category a download falls into (drives the colored type badge and
/// the sidebar "by type" filters). Derived purely from the task's name/source.
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

    /// Gradient colors matching the `.ft-*` classes in the mockup.
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

/// Where the detail panel is docked — right edge or bottom — mirroring
/// `AppSettings.detailPanelPosition`. Persisted, so it survives relaunch until the user flips it.
enum DetailPanelPosition: String, CaseIterable, Identifiable {
    case right = "Right"
    case bottom = "Bottom"
    var id: String { rawValue }

    /// The lowercase token persisted in `AppSettings.detailPanelPosition`.
    var settingsValue: String { rawValue.lowercased() }

    /// Reconstruct from the persisted token, defaulting to ``right`` for any
    /// unrecognized value.
    init(settingsValue: String) {
        self = DetailPanelPosition.allCases.first { $0.settingsValue == settingsValue } ?? .right
    }
}

/// The selectable named themes in Settings > General. Each is a complete look, not a light/dark
/// pair. Persisted through ``AppSettings/theme``.
enum AppTheme: String, CaseIterable, Identifiable {
    case frostLight = "Frost Light"
    case frostDark = "Frost Dark"
    case dracula = "Dracula"
    case nord = "Nord"
    var id: String { rawValue }

    /// The base appearance the theme sits on, driving `.preferredColorScheme` so system chrome and
    /// materials stay legible. Frost Light is the only light theme.
    var colorScheme: ColorScheme? {
        switch self {
        case .frostLight: return .light
        default: return .dark
        }
    }

    /// The semantic color set for this theme (accent + status colors + badges).
    var colors: ThemeColors {
        switch self {
        case .frostLight:
            // Green, orange and yellow are a shade darker than the mockup: as drawn they measured 3.76:1,
            // 4.38:1 and 4.16:1, under AA for the 10–12pt status text. Hue and saturation are unchanged.
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
            // Official Dracula palette; text colors picked to clear the
            // #282a36 canvas.
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
            // Official Nord palette on the #2e3440 canvas, except Aurora orange and purple (4.39:1 and
            // 4.41:1, just under AA) lifted one step in value to clear 4.5:1 while still reading as Nord.
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

    /// The window canvas wash for themes with a non-neutral background. `nil`
    /// for the Frost themes, which use the plain system canvas.
    var windowTint: Color? {
        switch self {
        case .frostLight, .frostDark: return nil
        case .dracula: return Color(hex: 0x282A36)
        case .nord:    return Color(hex: 0x2E3440)
        }
    }

    /// Resolve one semantic color to a SwiftUI `Color` bound to this theme's base appearance, so it
    /// renders the intended value even if composited under the opposite one.
    func resolvedColor(_ key: KeyPath<ThemeColors, ThemeColors.Pair>) -> Color {
        let pair = colors[keyPath: key]
        return Color.adaptive(light: pair.light, dark: pair.dark)
    }

    /// The lowercase, hyphenated token persisted in `AppSettings.theme`
    /// (e.g. "frost-dark"). `rawValue` stays human-readable for the picker.
    var settingsValue: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// Reconstruct from the persisted `AppSettings.theme` token. Legacy tokens ("system"/"light"/
    /// "dark") map onto the nearest new theme so existing installs upgrade rather than reset.
    init(settingsValue: String) {
        switch settingsValue {
        case "light": self = .frostLight
        case "dark", "system": self = .frostDark
        default:
            self = AppTheme.allCases.first { $0.settingsValue == settingsValue } ?? .frostDark
        }
    }
}
