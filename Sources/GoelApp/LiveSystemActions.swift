import AppKit
import Foundation
import GoelCore

struct LiveSystemActions: SystemActions {

    func post(_ notifications: [AppNotification], sound: Bool) {
        for notification in notifications {
            let title: String
            let body: String
            switch notification {
            case .added(let name):       title = L10n.t("Download added");   body = name
            case .completed(let name):   title = L10n.t("Download complete"); body = name
            case .failed(let name):      title = L10n.t("Download failed");   body = name
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
