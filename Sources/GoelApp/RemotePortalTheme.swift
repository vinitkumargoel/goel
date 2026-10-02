import Foundation

/// The web portal's look, stored in `AppSettings.remoteTheme`. Independent of the app's own
/// System / Light / Dark appearance (``StudioAppearanceMode``): the portal keeps its own themes,
/// and the stored tokens are the ones the portal page allowlists (`AppThemeToken`).
enum RemotePortalTheme: String, CaseIterable, Identifiable {
    case frostLight = "frost-light"
    case frostDark = "frost-dark"
    case dracula
    case nord

    var id: String { rawValue }

    /// The string written to `AppSettings.remoteTheme`.
    var storedValue: String { rawValue }

    /// Theme names are product names, shown untranslated.
    var title: String {
        switch self {
        case .frostLight: return "Frost Light"
        case .frostDark: return "Frost Dark"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        }
    }

    /// The legacy `"light"`/`"dark"`/`"system"` aliases still read back; anything unknown is
    /// Frost Dark, the portal's own default.
    init(storedValue: String) {
        switch storedValue {
        case "light": self = .frostLight
        case "dark", "system": self = .frostDark
        default: self = RemotePortalTheme(rawValue: storedValue) ?? .frostDark
        }
    }
}
