import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for the user-facing notifications
/// the Settings > Advanced pane toggles drive (download added / completed / failed).
///
/// Every call is guarded so it degrades to a silent no-op when the user has not
/// granted authorization — the app must never crash or block on a denied prompt.
enum NotificationService {

    /// Asks the system for alert + sound permission. The grant result is handled
    /// by the OS prompt, so the completion outcome is intentionally ignored here.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts an immediate banner. Skips delivery unless authorization is granted
    /// (or provisional) so toggles that are on but unpermitted simply do nothing.
    static func notify(title: String, body: String, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}
