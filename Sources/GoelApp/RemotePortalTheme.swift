import Foundation
import GoelCore

/// The web portal's look, stored in `AppSettings.remoteTheme`. Independent of the app's own
/// System / Light / Dark appearance (``StudioAppearanceMode``): this only sets what a browser
/// shows before its visitor picks a theme themselves. The tokens are the ones the portal page
/// allowlists (`AppThemeToken`).
enum RemotePortalTheme: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    /// The string written to `AppSettings.remoteTheme`.
    var storedValue: String { rawValue }

    var title: String {
        switch self {
        case .auto: return L10n.t("Match the device")
        case .light: return L10n.t("Light")
        case .dark: return L10n.t("Dark")
        }
    }

    /// Pre-Studio values read back the way the portal itself treats them: the Frost pair (the old
    /// default) followed the device, Dracula and Nord were deliberate dark picks, and anything
    /// unknown follows the device.
    init(storedValue: String) {
        switch storedValue {
        case "light": self = .light
        case "dark", "dracula", "nord": self = .dark
        default: self = .auto
        }
    }
}
