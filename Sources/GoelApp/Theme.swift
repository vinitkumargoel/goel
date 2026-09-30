import SwiftUI
import AppKit
import GoelCore

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

    /// Both strengthen under Increase Contrast: at 3%/10% the stripes and dividers vanish there.
    static let rowAlt = Color.primaryInk { rowAltAlpha($0) }
    static let hairline = Color.primaryInk { hairlineAlpha($0) }
    /// For dividers that separate controls rather than decorate: visible even without Increase Contrast.
    static let hairlineStrong = Color.primaryInk { $0.isHighContrast ? 0.55 : 0.18 }

    static func rowAltAlpha(_ variant: AppearanceVariant) -> CGFloat {
        variant.isHighContrast ? 0.08 : 0.03
    }

    static func hairlineAlpha(_ variant: AppearanceVariant) -> CGFloat {
        variant.isHighContrast ? 0.40 : 0.10
    }
}

/// Which of the four system appearances a drawing pass resolved to. The high-contrast
/// variants are what AppKit hands us when Increase Contrast is on.
struct AppearanceVariant: Equatable {
    let isDark: Bool
    let isHighContrast: Bool

    init(isDark: Bool, isHighContrast: Bool) {
        self.isDark = isDark
        self.isHighContrast = isHighContrast
    }

    init(_ name: NSAppearance.Name?) {
        switch name {
        case NSAppearance.Name.darkAqua, NSAppearance.Name.vibrantDark:
            self.init(isDark: true, isHighContrast: false)
        case NSAppearance.Name.accessibilityHighContrastDarkAqua,
             NSAppearance.Name.accessibilityHighContrastVibrantDark:
            self.init(isDark: true, isHighContrast: true)
        case NSAppearance.Name.accessibilityHighContrastAqua,
             NSAppearance.Name.accessibilityHighContrastVibrantLight:
            self.init(isDark: false, isHighContrast: true)
        default:
            self.init(isDark: false, isHighContrast: false)
        }
    }

    static let candidates: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    /// The workspace flag backs up the appearance match: an appearance built with
    /// `NSAppearance(named:)` never reports the high-contrast variant, only a drawing pass does.
    static func resolve(_ appearance: NSAppearance) -> AppearanceVariant {
        let matched = AppearanceVariant(appearance.bestMatch(from: candidates) ?? appearance.name)
        return AppearanceVariant(
            isDark: matched.isDark,
            isHighContrast: matched.isHighContrast || IncreaseContrast.isEnabled)
    }

    /// The fast path for colours that differ only between light and dark: no contrast flag needed.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        AppearanceVariant(appearance.bestMatch(from: candidates) ?? appearance.name).isDark
    }
}

/// System Settings ▸ Accessibility ▸ Increase contrast, read once and re-read only when the
/// display options change: every dynamic colour resolution used to ask NSWorkspace afresh.
enum IncreaseContrast {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Bool?
    private static let observer: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        object: nil, queue: nil
    ) { _ in
        IncreaseContrast.invalidate()
    }

    static var isEnabled: Bool {
        _ = observer
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let value = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        cached = value
        return value
    }

    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

struct ThemeColors {
    struct Pair: Equatable { let light: UInt32; let dark: UInt32 }
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

    /// Linear sRGB-channel blend: `t = 0` is `a`, `t = 1` is `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}

/// Fills for the file-type tiles. Each tile is a two-stop gradient built from one theme
/// token; the glyph ink is picked per fill so every stop clears AA.
enum IconFill {
    static let minimumContrast = 4.5
    /// `doc` has no hue of its own; grey-500/400 both clear AA against their picked ink.
    static let neutral = ThemeColors.Pair(light: 0x6B7280, dark: 0x9CA3AF)

    /// `top` is the token, nudged away from its ink only when it misses AA; `bottom` is
    /// shaded further from the ink, so it can only gain contrast.
    static func stops(for base: UInt32) -> (top: UInt32, bottom: UInt32, ink: UInt32) {
        let ink = WCAG.ink(on: base)
        let away: UInt32 = ink == 0xFFFFFF ? 0x000000 : 0xFFFFFF
        var top = base
        var step = 0.0
        while WCAG.contrastRatio(ink, top) < minimumContrast, step < 1 {
            step += 0.04
            top = WCAG.mix(base, away, step)
        }
        return (top, WCAG.mix(top, away, 0.18), ink)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Matches the high-contrast appearances too; without them Increase Contrast fell back to `.aqua`
    /// even in dark mode.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: AppearanceVariant.isDark(appearance) ? dark : light)
        })
    }

    /// `Color.primary` at an opacity chosen per appearance. The label colour is 85% black/white,
    /// so the alpha is scaled to match what `Color.primary.opacity(_:)` drew.
    static func primaryInk(_ alpha: @escaping @Sendable (AppearanceVariant) -> CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let variant = AppearanceVariant.resolve(appearance)
            let level: CGFloat = variant.isDark ? 1 : 0
            return NSColor(srgbRed: level, green: level, blue: level, alpha: 0.85 * alpha(variant))
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

    func fillToken(in theme: AppTheme) -> ThemeColors.Pair {
        let colors = theme.colors
        switch self {
        case .iso: return colors.orange
        case .video: return colors.purple
        case .archive: return colors.teal
        case .app: return colors.green
        case .magnet: return colors.red
        case .doc: return IconFill.neutral
        }
    }

    /// Follows the active theme; the fixed system-colour gradients ignored Dracula and Nord.
    var gradient: [Color] { FileTileCache.tile(for: self, theme: ThemePalette.current).gradient }

    /// Never hard-code white here: on the old archive blue it measured 1.72:1.
    var ink: Color { FileTileCache.tile(for: self, theme: ThemePalette.current).ink }
}

/// The file-type tile colours per (type, theme). The WCAG nudging loop used to run in every
/// icon's body; the inputs are fixed per theme, so each pair is worked out once.
enum FileTileCache {
    struct Stops: Equatable {
        let light: (top: UInt32, bottom: UInt32, ink: UInt32)
        let dark: (top: UInt32, bottom: UInt32, ink: UInt32)

        init(for type: FileType, theme: AppTheme) {
            let pair = type.fillToken(in: theme)
            light = IconFill.stops(for: pair.light)
            dark = IconFill.stops(for: pair.dark)
        }

        static func == (a: Stops, b: Stops) -> Bool {
            a.light == b.light && a.dark == b.dark
        }
    }

    struct Tile {
        let stops: Stops
        let gradient: [Color]
        let ink: Color
    }

    private struct Key: Hashable { let type: FileType; let theme: AppTheme }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tiles: [Key: Tile] = [:]
    /// How many tiles have been worked out; tests read it to prove the cache is hit.
    nonisolated(unsafe) private(set) static var computeCount = 0

    static func tile(for type: FileType, theme: AppTheme) -> Tile {
        let key = Key(type: type, theme: theme)
        lock.lock()
        defer { lock.unlock() }
        if let tile = tiles[key] { return tile }
        let stops = Stops(for: type, theme: theme)
        let tile = Tile(stops: stops,
                        gradient: [Color.adaptive(light: stops.light.top, dark: stops.dark.top),
                                   Color.adaptive(light: stops.light.bottom, dark: stops.dark.bottom)],
                        ink: Color.adaptive(light: stops.light.ink, dark: stops.dark.ink))
        tiles[key] = tile
        computeCount += 1
        return tile
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

/// The only settings the `App` struct's scenes read. Kept apart so its `body` re-runs when the
/// theme or the menu-bar switch changes, not on every published change of the view model.
@MainActor
final class AppAppearance: ObservableObject {
    @Published private(set) var colorScheme: ColorScheme?
    @Published private(set) var menuBarExtraEnabled: Bool

    init(settings: AppSettings = AppSettings()) {
        colorScheme = AppTheme(settingsValue: settings.theme).colorScheme
        menuBarExtraEnabled = settings.menuBarExtraEnabled
    }

    /// Assigns only on change: `@Published` publishes every write, equal or not.
    func apply(_ settings: AppSettings) {
        let scheme = AppTheme(settingsValue: settings.theme).colorScheme
        if scheme != colorScheme { colorScheme = scheme }
        if settings.menuBarExtraEnabled != menuBarExtraEnabled { menuBarExtraEnabled = settings.menuBarExtraEnabled }
    }
}
