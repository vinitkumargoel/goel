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
            // Attach the app mark so a logo shows on the banner even when the
            // system doesn't surface the bundle icon (e.g. an unbundled/dev run).
            if let icon = iconAttachment() {
                content.attachments = [icon]
            }

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    /// A logo attachment for the notification banner. The bundled icon is copied
    /// to a unique temp file first because `UNNotificationAttachment` takes
    /// ownership of (moves) the file it's handed and can't move a read-only
    /// bundle resource. Returns nil (silently, no attachment) if anything fails.
    private static func iconAttachment() -> UNNotificationAttachment? {
        guard let src = Bundle.module.url(forResource: "AppIcon-Light", withExtension: "png") else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-notify-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: src, to: tmp)
            return try UNNotificationAttachment(identifier: "goel-icon", url: tmp, options: nil)
        } catch {
            return nil
        }
    }
}
