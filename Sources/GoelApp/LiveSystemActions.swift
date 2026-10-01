import AppKit
import Foundation
import GoelCore

/// Completion banners carry the task, so they can offer Show in Finder / Open and replace
/// an earlier banner for the same download; ``AppNotification`` only knows the name.
protocol CompletionNotifying {
    func postCompleted(taskID: UUID, name: String, sound: Bool)
    func postCompletedSummary(count: Int, body: String, sound: Bool)
    func postFailed(taskID: UUID, name: String, reason: String, sound: Bool)
}

struct LiveSystemActions: SystemActions, CompletionNotifying {

    func postCompleted(taskID: UUID, name: String, sound: Bool) {
        NotificationService.notifyCompleted(taskID: taskID, name: name, sound: sound)
    }

    func postCompletedSummary(count: Int, body: String, sound: Bool) {
        NotificationService.notifyCompletedSummary(count: count, body: body, sound: sound)
    }

    func postFailed(taskID: UUID, name: String, reason: String, sound: Bool) {
        NotificationService.notifyFailed(taskID: taskID, name: name, reason: reason, sound: sound)
    }

    func post(_ notifications: [AppNotification], sound: Bool) {
        for notification in notifications {
            let title: String
            let body: String
            switch notification {
            case .added(let name):       title = L10n.t("Download added");   body = name
            case .completed(let name):   title = L10n.t("Download complete"); body = name
            case .failed(let name):
                title = NotificationPlanning.failureTitle(name: name)
                body = L10n.t("The download stopped with an error.")
            case .scanFlagged(let name): title = L10n.t("Antivirus flagged a file"); body = name
            }
            NotificationService.notify(title: title, body: body, sound: sound)
        }
    }

    func perform(_ intent: DrainIntent) {
        switch intent {
        case .quit:
            NSApp.terminate(nil)
        case .sleep:
            let pmset = Process()
            pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmset.arguments = ["sleepnow"]
            do {
                try pmset.run()
            } catch {
                NotificationService.notify(
                    title: L10n.t("Couldn’t put this Mac to sleep"),
                    body: L10n.t("Downloads finished, but the sleep command didn’t run."),
                    sound: false
                )
            }
        case .shutdown:
            // Via System Events so the user gets the normal unsaved-work prompts.
            let source = "tell application \"System Events\" to shut down"
            guard let script = NSAppleScript(source: source) else {
                NotificationService.notify(
                    title: L10n.t("Couldn’t shut this Mac down"),
                    body: L10n.t("Downloads finished, but the shutdown command couldn’t be prepared."),
                    sound: false
                )
                return
            }
            var failure: NSDictionary?
            script.executeAndReturnError(&failure)
            if failure != nil {
                NotificationService.notify(
                    title: L10n.t("Couldn’t shut this Mac down"),
                    body: L10n.t("Downloads finished, but macOS blocked the request. "
                        + "Allow Goel° to control System Events in System Settings "
                        + "→ Privacy & Security → Automation."),
                    sound: false
                )
            }
        }
    }
}
