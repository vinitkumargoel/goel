import Foundation
import GoelCore
import UserNotifications

enum NotificationService {

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil
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

    /// Copy to a temp file first: `UNNotificationAttachment` *moves* what it is handed and cannot move a read-only bundle resource.
    private static func iconAttachment() -> UNNotificationAttachment? {
        guard let src = ResourceBundles.app?.url(forResource: "AppIcon-Light", withExtension: "png") else { return nil }
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
