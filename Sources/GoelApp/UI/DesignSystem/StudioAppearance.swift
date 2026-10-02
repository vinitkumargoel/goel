import SwiftUI
import AppKit
import GoelCore

/// Studio's appearance setting: exactly System, Light or Dark. It replaces the old palette picker
/// (Frost Light, Frost Dark, Dracula, Nord).
///
/// Storage stays `AppSettings.theme`, a free-form string in GoelCore's settings row, so the format
/// is backward compatible both ways:
/// - old values are read through ``init(storedValue:)`` (Frost Light → Light; Frost Dark, Dracula,
///   Nord → Dark; anything unknown → System) and are never rewritten behind the user's back;
/// - the new values `"system"`, `"light"` and `"dark"` were already aliases the old palette
///   picker accepted, so an older build reading them keeps working.
/// The web portal's look is a separate field (`AppSettings.remoteTheme`, see ``RemotePortalTheme``).
enum StudioAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The string written to `AppSettings.theme`.
    var storedValue: String { rawValue }

    /// Migrates any stored `AppSettings.theme` value.
    init(storedValue: String) {
        switch storedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "system": self = .system
        case "light", "frost-light": self = .light
        case "dark", "frost-dark", "dracula", "nord": self = .dark
        default: self = .system
        }
    }

    /// For `.preferredColorScheme(_:)`. System is nil, which follows the Mac.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// For AppKit windows and panels that SwiftUI's scene modifiers don't reach.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var title: String {
        switch self {
        case .system: return L10n.t("System")
        case .light: return L10n.t("Light")
        case .dark: return L10n.t("Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// ⇧⌘T: flips what is on screen. From System it pins the opposite of the current look.
    func toggled(currentlyDark: Bool) -> StudioAppearanceMode {
        switch self {
        case .light: return .dark
        case .dark: return .light
        case .system: return currentlyDark ? .light : .dark
        }
    }
}

extension AppViewModel {
    /// The appearance setting new views read and write. Writes go through `update`, like every
    /// other setting, so they persist and reach `AppAppearance`.
    var appearanceMode: StudioAppearanceMode {
        get { StudioAppearanceMode(storedValue: settings.theme) }
        set {
            let value = newValue.storedValue
            update { $0.theme = value }
        }
    }

    /// Toggle Theme (⇧⌘T).
    func toggleAppearanceMode() {
        let isDark = AppearanceVariant.isDark(NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing())
        appearanceMode = appearanceMode.toggled(currentlyDark: isDark)
    }
}

/// The only settings the `App` struct's scenes read. Kept apart so its `body` re-runs when the
/// theme or the menu-bar switch changes, not on every published change of the view model.
@MainActor
final class AppAppearance: ObservableObject {
    @Published private(set) var colorScheme: ColorScheme?
    /// The Studio appearance setting (System / Light / Dark), migrated from whatever
    /// `AppSettings.theme` holds; see ``StudioAppearanceMode``.
    @Published private(set) var mode: StudioAppearanceMode
    @Published private(set) var menuBarExtraEnabled: Bool

    init(settings: AppSettings = AppSettings()) {
        let mode = StudioAppearanceMode(storedValue: settings.theme)
        self.mode = mode
        colorScheme = mode.colorScheme
        menuBarExtraEnabled = settings.menuBarExtraEnabled
    }

    /// Assigns only on change: `@Published` publishes every write, equal or not.
    func apply(_ settings: AppSettings) {
        let next = StudioAppearanceMode(storedValue: settings.theme)
        if next != mode {
            mode = next
            colorScheme = next.colorScheme
            // `preferredColorScheme(nil)` doesn't always hand a window back to the system look;
            // the application-wide appearance does, and it reaches AppKit panels too.
            NSApp?.appearance = next.nsAppearance
        }
        if settings.menuBarExtraEnabled != menuBarExtraEnabled { menuBarExtraEnabled = settings.menuBarExtraEnabled }
    }
}
