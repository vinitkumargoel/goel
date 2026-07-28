import Foundation
import AppKit

// Apple events arrive on the main thread, which is what makes `assumeIsolated` below safe.

@objc(AddDownloadScriptCommand)
final class AddDownloadScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let line = directParameter as? String,
              !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            scriptErrorString = "Pass the URL to download."
            return nil
        }
        // Trusted local automation only — web-origin adds must not be routed here, they need the banner.
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
