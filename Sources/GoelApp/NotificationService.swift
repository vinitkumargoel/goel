import AppKit
import Foundation
import GoelCore
import UserNotifications

enum NotificationService {

    static let completedCategory = "download.completed"
    static let threadIdentifier = "downloads"
    static let taskIDKey = "taskID"

    enum Action: String {
        case reveal = "download.reveal"
        case open = "download.open"
    }

    /// What a click on a banner (or one of its buttons) asks for.
    enum Response: Equatable {
        case reveal(UUID)
        case open(UUID)
        case show(UUID)
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Must run at launch, before the first banner: a click that launches the app is delivered
    /// to whichever delegate is set by then.
    @MainActor
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared
        center.setNotificationCategories([completedCategoryDefinition])
    }

    static var completedCategoryDefinition: UNNotificationCategory {
        UNNotificationCategory(
            identifier: completedCategory,
            actions: [
                UNNotificationAction(identifier: Action.reveal.rawValue,
                                     title: L10n.t("Show in Finder"), options: [.foreground]),
                UNNotificationAction(identifier: Action.open.rawValue,
                                     title: L10n.t("Open"), options: [.foreground]),
            ],
            intentIdentifiers: [])
    }

    static func notify(title: String, body: String, sound: Bool) {
        post(identifier: UUID().uuidString, content: content(title: title, body: body, sound: sound))
    }

    /// One identifier per task, so a re-notification replaces the earlier banner instead of stacking.
    static func notifyCompleted(taskID: UUID, name: String, sound: Bool) {
        post(identifier: identifier(for: taskID),
             content: completedContent(taskID: taskID, name: name, sound: sound))
    }

    static func identifier(for taskID: UUID) -> String { "task-\(taskID.uuidString)" }

    static func content(title: String, body: String, sound: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        content.threadIdentifier = threadIdentifier
        return content
    }

    static func completedContent(taskID: UUID, name: String, sound: Bool) -> UNMutableNotificationContent {
        let content = content(title: L10n.t("Download complete"), body: name, sound: sound)
        content.categoryIdentifier = completedCategory
        content.userInfo = [taskIDKey: taskID.uuidString]
        return content
    }

    static func response(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Response? {
        guard let raw = userInfo[taskIDKey] as? String, let id = UUID(uuidString: raw) else { return nil }
        switch actionIdentifier {
        case Action.reveal.rawValue: return .reveal(id)
        case Action.open.rawValue: return .open(id)
        case UNNotificationDefaultActionIdentifier: return .show(id)
        default: return nil
        }
    }

    private static func post(identifier: String, content: UNMutableNotificationContent) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            if let icon = iconAttachment() {
                content.attachments = [icon]
            }
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
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

/// Without a delegate macOS drops banners while the app is frontmost and clicks do nothing.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    /// Set by the view model: "notify only when Goel° is in the background" also governs
    /// banners that arrive while it is in front.
    @MainActor var suppressWhileActive: () -> Bool = { false }
    @MainActor var onResponse: (NotificationService.Response) -> Void = { _ in }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let suppress = self.suppressWhileActive() && NSApp.isActive
            completionHandler(suppress ? [] : [.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = NotificationService.response(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let action { self.onResponse(action) }
            completionHandler()
        }
    }
}
