import AppKit
import Foundation
import GoelCore
import UserNotifications

enum NotificationService {

    static let completedCategory = "download.completed"
    static let autoShutdownCategory = "autoshutdown.countdown"
    static let autoShutdownIdentifier = "autoshutdown"
    static let threadIdentifier = "downloads"
    static let taskIDKey = "taskID"

    enum Action: String {
        case reveal = "download.reveal"
        case open = "download.open"
        case cancelAutoShutdown = "autoshutdown.cancel"
    }

    /// What a click on a banner (or one of its buttons) asks for.
    enum Response: Equatable {
        case reveal(UUID)
        case open(UUID)
        case show(UUID)
        case cancelAutoShutdown
        case showAutoShutdown
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// What System Settings allows, for the Notifications pane's status row.
    enum Permission: Equatable {
        case allowed, denied, notAsked
    }

    static func permission() async -> Permission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .notAsked
        }
    }

    /// The pane's "Send Test": proof that banners arrive, without waiting for a download.
    static func sendTest(sound: Bool) {
        let content = content(title: L10n.t("Notifications are working"),
                              body: L10n.t("This is how Goel° tells you a download finished or failed."),
                              sound: sound)
        post(identifier: "test-\(UUID().uuidString)", content: content)
    }

    @MainActor
    static func openSystemSettings() {
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let target = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundle)"
        if let url = URL(string: target) { NSWorkspace.shared.open(url) }
    }

    /// Must run at launch, before the first banner: a click that launches the app is delivered
    /// to whichever delegate is set by then.
    @MainActor
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared
        center.setNotificationCategories([completedCategoryDefinition, autoShutdownCategoryDefinition])
    }

    static var autoShutdownCategoryDefinition: UNNotificationCategory {
        UNNotificationCategory(
            identifier: autoShutdownCategory,
            actions: [UNNotificationAction(identifier: Action.cancelAutoShutdown.rawValue,
                                           title: L10n.t("Cancel"), options: [])],
            intentIdentifiers: [])
    }

    /// Posted when the auto quit/sleep/shutdown countdown starts; nothing else says so outside the window.
    static func notifyAutoShutdown(title: String, body: String) {
        let content = content(title: title, body: body, sound: true)
        content.categoryIdentifier = autoShutdownCategory
        content.interruptionLevel = .timeSensitive
        post(identifier: autoShutdownIdentifier, content: content)
    }

    static func retractAutoShutdown() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [autoShutdownIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [autoShutdownIdentifier])
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

    static func response(actionIdentifier: String, categoryIdentifier: String = "",
                         userInfo: [AnyHashable: Any]) -> Response? {
        if categoryIdentifier == autoShutdownCategory {
            switch actionIdentifier {
            case Action.cancelAutoShutdown.rawValue: return .cancelAutoShutdown
            case UNNotificationDefaultActionIdentifier: return .showAutoShutdown
            default: return nil
            }
        }
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

    /// A click that cold-launches the app arrives before the view model has restored the queue:
    /// it waits here until ``setResponseHandler(_:)`` installs someone who can act on it.
    @MainActor private var onResponse: ((NotificationService.Response) -> Void)?
    @MainActor private(set) var buffered: [NotificationService.Response] = []

    @MainActor
    func setResponseHandler(_ handler: @escaping (NotificationService.Response) -> Void) {
        onResponse = handler
        let waiting = buffered
        buffered = []
        waiting.forEach(handler)
    }

    @MainActor
    func deliver(_ response: NotificationService.Response) {
        if let onResponse { onResponse(response) } else { buffered.append(response) }
    }

    /// Frontmost with a main window showing, the in-window toast already says it; a banner would double it.
    @MainActor
    static func shouldSuppress(isActive: Bool, onlyWhenInactive: Bool, showingMainWindow: Bool) -> Bool {
        isActive && (onlyWhenInactive || showingMainWindow)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            // The countdown banner is the one way a menu-bar-only user learns the Mac is about to power off.
            let isCountdown = notification.request.identifier == NotificationService.autoShutdownIdentifier
            let suppress = !isCountdown && Self.shouldSuppress(
                isActive: NSApp.isActive, onlyWhenInactive: self.suppressWhileActive(),
                showingMainWindow: MainWindowPresenter.isShowingMainWindow)
            completionHandler(suppress ? [] : [.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = NotificationService.response(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let action { self.deliver(action) }
            completionHandler()
        }
    }
}
