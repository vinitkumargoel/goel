import Foundation
import GoelCore

/// The queue profile picker's view of the settings (Low · Medium · High in the status bar), so the
/// view asks the model what it may show and do instead of reading settings and managed policy.
@MainActor
extension AppViewModel {

    /// The profiles in the order the picker lists them.
    var queueProfiles: [TrafficProfile] { settings.profiles }

    var activeProfileName: String { settings.selectedProfileName }

    /// What choosing `profile` changes, with its caps marked off while the speed limit is off
    /// (``SpeedProfileText/queueSummary(_:limitEnabled:)``).
    func queueSummary(for profile: TrafficProfile) -> String {
        SpeedProfileText.queueSummary(profile, limitEnabled: settings.speedLimitEnabled)
    }

    /// The same summary worded for VoiceOver.
    func spokenQueueSummary(for profile: TrafficProfile) -> String {
        SpeedProfileText.spokenQueueSummary(profile, limitEnabled: settings.speedLimitEnabled)
    }

    /// Whether Edit Profile… may open `name`. Editing makes a profile the active one, so a managed
    /// policy that pins the selection leaves only the active profile editable.
    func canEditProfile(named name: String) -> Bool {
        Self.canEditProfile(named: name, active: settings.selectedProfileName,
                            selectionLocked: managedPolicy.isLocked(.selectedProfileName))
    }

    nonisolated static func canEditProfile(named name: String, active: String, selectionLocked: Bool) -> Bool {
        name == active || !selectionLocked
    }

    /// The first half of Edit Profile…: the Speed & Connections pane edits the active profile, so
    /// `name` becomes active and the pane is requested. The caller then opens the Settings window.
    func prepareToEditProfile(named name: String) {
        if name != settings.selectedProfileName { setProfile(name) }
        SettingsRoute.shared.request(.traffic)
    }
}
