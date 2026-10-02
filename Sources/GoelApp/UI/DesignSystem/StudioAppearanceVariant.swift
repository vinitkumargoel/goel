import AppKit

// Moved out of Theme.swift unchanged: both the old palette and the Studio tokens resolve
// through these, and Theme.swift is deleted once the Studio rewrite lands.

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

/// WCAG 2.1 contrast arithmetic, shared by the old palette and the Studio token tests.
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
