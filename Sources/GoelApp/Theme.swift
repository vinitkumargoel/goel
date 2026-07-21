import SwiftUI
import AppKit

/// The semantic palette used across the app (accent, status colors, badges).
///
/// Colors resolve against the **currently selected named theme**
/// (``ThemePalette``), not just the system light/dark appearance. Selecting a
/// theme in Settings updates ``ThemePalette/current`` and refreshes the UI, so
/// every `Theme.accent`/`Theme.green`/… call site adopts that theme's identity
/// with no per-view plumbing.
///
/// Each value is still backed by a dynamic `NSColor` so it tracks the theme's
/// **base appearance** (Frost Light is an Aqua theme; Frost Dark / Dracula /
/// Nord are Dark Aqua themes). Every palette was picked to keep normal text
/// legible against that theme's canvas.
enum Theme {
    static var accent:      Color { ThemePalette.color(\.accent) }
    static var accentPress: Color { ThemePalette.color(\.accentPress) }
    static var green:       Color { ThemePalette.color(\.green) }
    static var orange:      Color { ThemePalette.color(\.orange) }
    static var red:         Color { ThemePalette.color(\.red) }
    static var purple:      Color { ThemePalette.color(\.purple) }
    static var teal:        Color { ThemePalette.color(\.teal) }
    static var indigo:      Color { ThemePalette.color(\.indigo) }

    /// An optional wash tint applied over the window canvas so themes with a
    /// non-neutral background (Dracula's blue-gray, Nord's polar night) read as
    /// that color even though the app's chrome is built from system materials.
    /// `nil` for the Frost themes, which sit on the plain system canvas.
    static var windowTint: Color? { ThemePalette.current.windowTint }

    /// Subtle alternating-row tint.
    static let rowAlt = Color.primary.opacity(0.03)
    static let hairline = Color.primary.opacity(0.10)
}

/// The full set of semantic colors for one named theme, each as a `light`/`dark`
/// hex pair. Only one of the two is normally used (a theme has a single base
/// appearance), but keeping both lets a value stay legible if the OS ever
/// composites it under the opposite appearance.
struct ThemeColors {
    struct Pair { let light: UInt32; let dark: UInt32 }
    let accent, accentPress, green, orange, red, yellow, purple, teal, indigo: Pair
}

/// Holds the active theme and resolves ``ThemeColors`` into SwiftUI `Color`s
/// bound to that theme's base appearance. `current` is read on the main thread
/// during view updates; the app sets it whenever the persisted theme changes.
enum ThemePalette {
    /// The active theme. Defaults to Frost Dark; the app overrides this from the
    /// persisted setting at launch and on every change.
    ///
    /// Marked `nonisolated(unsafe)` because it is read from view code that isn't
    /// always main-actor isolated (e.g. `TaskDisplay`'s computed color helpers),
    /// while writes only ever happen on the main thread from `AppViewModel`.
    /// A single enum value read/write is effectively atomic, so this is safe.
    nonisolated(unsafe) static var current: AppTheme = .frostDark

    static func color(_ key: KeyPath<ThemeColors, ThemeColors.Pair>) -> Color {
        current.resolvedColor(key)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// A color that resolves to `light` under Aqua and `dark` under Dark Aqua,
    /// tracking the window's effective appearance — including the theme the user
    /// forces from Settings via `.preferredColorScheme`. Backed by a dynamic
    /// `NSColor` so every call site adapts with no per-view `@Environment` reads.
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

/// Where the detail panel is docked — the right edge or the bottom edge —
/// mirroring `AppSettings.detailPanelPosition`. The choice is persisted so it
/// holds across selections and survives relaunch until the user flips it.
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

/// The selectable named themes surfaced in Settings > General. Each is a
/// complete, independent look (not a light/dark pair): Frost ships a light and a
/// dark variant, and Dracula and Nord are popular community palettes. The choice
/// is persisted through ``AppSettings/theme`` so it survives relaunch.
enum AppTheme: String, CaseIterable, Identifiable {
    case frostLight = "Frost Light"
    case frostDark = "Frost Dark"
    case dracula = "Dracula"
    case nord = "Nord"
    var id: String { rawValue }

    /// The base appearance the theme sits on, driving `.preferredColorScheme` so
    /// system chrome, materials, and text stay legible. Frost Light is the only
    /// light theme; the rest are dark.
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
            return ThemeColors(
                accent:      .init(light: 0x3F58D6, dark: 0x5B7CFA),
                accentPress: .init(light: 0x2E45B8, dark: 0x4F6EF0),
                green:       .init(light: 0x158A3C, dark: 0x2FBF5B),
                orange:      .init(light: 0xA85800, dark: 0xE08A1E),
                red:         .init(light: 0xCE0E0E, dark: 0xE24B4B),
                yellow:      .init(light: 0x8A6D00, dark: 0xD1A93A),
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
            // Official Nord palette on the #2e3440 polar-night canvas.
            return ThemeColors(
                accent:      .init(light: 0x5E81AC, dark: 0x88C0D0),
                accentPress: .init(light: 0x4C6E96, dark: 0x81A1C1),
                green:       .init(light: 0x6E9A5A, dark: 0xA3BE8C),
                orange:      .init(light: 0xC1794A, dark: 0xD08770),
                red:         .init(light: 0xBF616A, dark: 0xE08691),
                yellow:      .init(light: 0xA88A3E, dark: 0xEBCB8B),
                purple:      .init(light: 0x8A6BB0, dark: 0xB48EAD),
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

    /// Resolve one semantic color to a SwiftUI `Color` bound to this theme's base
    /// appearance, so it renders the intended value even if composited under the
    /// opposite appearance.
    func resolvedColor(_ key: KeyPath<ThemeColors, ThemeColors.Pair>) -> Color {
        let pair = colors[keyPath: key]
        return Color.adaptive(light: pair.light, dark: pair.dark)
    }

    /// The lowercase, hyphenated token persisted in `AppSettings.theme`
    /// (e.g. "frost-dark"). `rawValue` stays human-readable for the picker.
    var settingsValue: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// Reconstruct from the persisted `AppSettings.theme` token. Legacy tokens
    /// ("system"/"light"/"dark") map onto the nearest new theme so existing
    /// installs upgrade cleanly rather than resetting.
    init(settingsValue: String) {
        switch settingsValue {
        case "light": self = .frostLight
        case "dark", "system": self = .frostDark
        default:
            self = AppTheme.allCases.first { $0.settingsValue == settingsValue } ?? .frostDark
        }
    }
}
