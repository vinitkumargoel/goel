import Foundation
import AppKit

// AppleScript / Automator / Shortcuts-via-Run-AppleScript surface.
//
// The packaged app's Info.plist enables scripting (`NSAppleScriptEnabled`)
// and points `OSAScriptingDefinition` at `GoelDownloader.sdef`, whose command
// entries name these classes. Apple events are delivered on the main thread,
// so hopping straight into the main-actor view model is sound.
//
// Example:
//   tell application "GoelDownloader"
//       add download "https://example.com/file.zip"
//       pause all downloads
//   end tell

@objc(AddDownloadScriptCommand)
final class AddDownloadScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let line = directParameter as? String,
              !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            scriptErrorString = "Pass the URL to download."
            return nil
        }
        // Same trusted local-automation path as the Services menu: the user
        // wrote the script, so no web-origin confirmation banner.
        MainActor.assumeIsolated {
            ExternalAdd.post(lines: line)
        }
        return nil
    }
}

@objc(PauseAllScriptCommand)
final class PauseAllScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { AppViewModel.shared?.pauseAll() }
        return nil
    }
}

@objc(ResumeAllScriptCommand)
final class ResumeAllScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { AppViewModel.shared?.resumeAll() }
        return nil
    }
}

@objc(CountDownloadsScriptCommand)
final class CountDownloadsScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { AppViewModel.shared?.tasks.count ?? 0 }
    }
}
