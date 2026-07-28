import AppKit
import Foundation
import GoelCore

/// The production ``SystemActions``: posts banners and performs the irreversible drain action
/// (quit / sleep / shutdown). Stateless, so the pure reducer's decision is testable without it.
struct LiveSystemActions: SystemActions {

    func post(_ notifications: [AppNotification], sound: Bool) {
        for notification in notifications {
            let title: String
            let body: String
            switch notification {
            case .added(let name):       title = "Download added";          body = name
            case .completed(let name):   title = "Download complete";       body = name
            case .failed(let name):      title = "Download failed";         body = name
            case .scanFlagged(let name): title = "Antivirus flagged a file"; body = name
            }
            NotificationService.notify(title: title, body: body, sound: sound)
        }
    }

    // Both drain actions were asked for hours earlier and then walked away from. Discarding the
    // failure left the Mac awake with nothing saying why; a banner is imperfect but beats silence.
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
                    title: "Couldn’t put this Mac to sleep",
                    body: "Downloads finished, but the sleep command didn’t run.",
                    sound: false
                )
            }
        case .shutdown:
            // Via System Events so the user gets the normal unsaved-work prompts.
            let source = "tell application \"System Events\" to shut down"
            guard let script = NSAppleScript(source: source) else {
                NotificationService.notify(
                    title: "Couldn’t shut this Mac down",
                    body: "Downloads finished, but the shutdown command couldn’t be prepared.",
                    sound: false
                )
                return
            }
            var failure: NSDictionary?
            script.executeAndReturnError(&failure)
            if failure != nil {
                // Overwhelmingly this is a declined (or never-granted) Automation
                // permission, and the user can only fix it in one place.
                NotificationService.notify(
                    title: "Couldn’t shut this Mac down",
                    body: "Downloads finished, but macOS blocked the request. "
                        + "Allow Goel° to control System Events in System Settings "
                        + "→ Privacy & Security → Automation.",
                    sound: false
                )
            }
        }
    }
}
