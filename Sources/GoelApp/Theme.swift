import SwiftUI

/// The palette lifted from `visual.html` so the native app matches the mockup.
/// Accent blue, status greens/oranges/reds, and the BT purple / HTTP teal.
enum Theme {
    static let accent = Color(hex: 0x0A84FF)
    static let accentPress = Color(hex: 0x0060DF)
    static let green = Color(hex: 0x32D74B)
    static let orange = Color(hex: 0xFF9F0A)
    static let red = Color(hex: 0xFF453A)
    static let yellow = Color(hex: 0xFFD60A)
    static let purple = Color(hex: 0xBF5AF2)
    static let teal = Color(hex: 0x64D2FF)

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
}
