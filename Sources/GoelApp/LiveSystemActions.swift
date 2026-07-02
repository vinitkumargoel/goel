import AppKit
import Foundation
import GoelCore

/// The production ``SystemActions``: posts banners through ``NotificationService``
/// and performs the irreversible queue-drain action (quit / sleep / shutdown).
///
/// It holds no state, so it is trivially `Sendable`; its methods are only ever
/// called from the main-actor snapshot pump. Extracting this behind the port lets
/// the pure ``SnapshotReducer`` decide *whether* to shut the Mac down while a test
/// asserts the decision without ever spawning `pmset` or terminating the app.
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

    func perform(_ intent: DrainIntent) {
        switch intent {
        case .quit:
            NSApp.terminate(nil)
        case .sleep:
            let pmset = Process()
            pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmset.arguments = ["sleepnow"]
            try? pmset.run()
        case .shutdown:
            // Via System Events so the user gets the normal unsaved-work prompts.
            let script = NSAppleScript(source: "tell application \"System Events\" to shut down")
            script?.executeAndReturnError(nil)
        }
    }
}
