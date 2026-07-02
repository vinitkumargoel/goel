import SwiftUI
import AppKit

/// The palette, derived from `visual.html` but made **appearance-adaptive** so
/// text stays legible in both light and dark mode.
///
/// The original mockup used Apple's *dark-mode* vibrant system tints (e.g. the
/// bright `0x32D74B` green, `0x64D2FF` teal). Those read well on black but, used
/// unchanged on a light background, drop to ~1.3–1.9:1 contrast as text —
/// effectively invisible. Each semantic color therefore resolves to two values:
/// the vibrant tint under Dark Aqua, and a darkened, saturated variant under
/// Aqua. Both palettes were checked to clear WCAG AA (≥ 4.5:1) for normal text
/// against their respective backgrounds, the same way the system semantic
/// colors adapt.
enum Theme {
    static let accent      = Color.adaptive(light: 0x0066CC, dark: 0x0A84FF)
    static let accentPress = Color.adaptive(light: 0x004FAC, dark: 0x0060DF)
    static let green       = Color.adaptive(light: 0x14803C, dark: 0x32D74B)
    static let orange      = Color.adaptive(light: 0xA85800, dark: 0xFF9F0A)
    static let red         = Color.adaptive(light: 0xCE0E0E, dark: 0xFF6961)
    static let yellow      = Color.adaptive(light: 0x8A6D00, dark: 0xFFD60A)
    static let purple      = Color.adaptive(light: 0x8A2BE0, dark: 0xCB6FF5)
    static let teal        = Color.adaptive(light: 0x0E7C99, dark: 0x64D2FF)
    static let indigo      = Color.adaptive(light: 0x3634A3, dark: 0x7D7AFF)

    /// Subtle alternating-row tint.
    static let rowAlt = Color.primary.opacity(0.03)
    static let hairline = Color.primary.opacity(0.10)
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

    var displayName: String {
        switch self {
        case .iso: return "Disc images"
        case .video: return "Video"
        case .archive: return "Archives"
        case .app: return "Apps"
        case .magnet: return "Magnet"
        case .doc: return "Documents"
        }
    }

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

/// Light / dark / system, mirroring the Settings > General theme control.
enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The lowercase token persisted in `AppSettings.theme` ("system" | "light" |
    /// "dark"). `rawValue` stays capitalized for the segmented-picker labels, so
    /// this small bridge keeps the core's `String` field and the app enum aligned.
    var settingsValue: String { rawValue.lowercased() }

    /// Reconstruct from the persisted `AppSettings.theme` token, defaulting to
    /// ``system`` for any unrecognized value.
    init(settingsValue: String) {
        self = AppTheme.allCases.first { $0.settingsValue == settingsValue } ?? .system
    }
}
