import Foundation
import GoelCore

/// Plain `UserDefaults`, never ``AppSettings``: a backup import must not be able to replay first run.
enum OnboardingState {

    /// Bumping this re-shows the whole flow to every existing user.
    static let currentVersion = 1

    private static let completedVersionKey = "onboarding.completedVersion"
    private static let licenceNoticeDismissedKey = "onboarding.licenceNoticeDismissed"

    static var needsOnboarding: Bool {
        UserDefaults.standard.integer(forKey: completedVersionKey) < currentVersion
    }

    static func markCompleted() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
    }

    static var licenceNoticeDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: licenceNoticeDismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: licenceNoticeDismissedKey) }
    }

    static let commercialURL = URL(string: "https://goel.vinitk.dev/commercial")!
}

/// The first onboarding question. The answer only tailors the steps shown; nothing is locked in.
enum OnboardingBrowserChoice: String, CaseIterable, Identifiable {
    case chrome, safari, firefox, edge, brave, arc, other

    static let storageKey = "onboarding.browser"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .other: return L10n.t("Other")
        }
    }

    /// Safari ships inside the app; everything Chromium or Gecko needs the helper + unpacked extension.
    var needsHelper: Bool { self != .safari && self != .other }

    var loadHint: String {
        switch self {
        case .firefox:
            return L10n.t("about:debugging → This Firefox → Load Temporary Add-on → "
                + "the folder’s manifest.json. Reload it after each Firefox restart.")
        case .safari, .other:
            return ""
        default:
            return L10n.t("Open the extensions page → Developer mode → Load unpacked → the folder.")
        }
    }
}
