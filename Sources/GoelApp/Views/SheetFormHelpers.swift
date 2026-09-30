import Foundation
import GoelCore

/// Pure decisions behind the Add Download sheet, kept out of the view so they can be tested.
enum AddSheetInput {

    /// The clipboard lines worth prefilling: every line that yields at least one source.
    /// `nil` when nothing parses, so ordinary copied prose never lands in the box.
    static func clipboardPrefill(_ clip: String?) -> String? {
        guard let clip else { return nil }
        let lines = clip
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !InboundAdd.parseSources(from: $0).isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// "Advanced options" opens on its own when any of its fields already carries a value,
    /// so a pre-filled checksum or an attached cookie is never hidden behind a closed group.
    static func advancedHasContent(checksum: String, mirrors: String, cookieSource: CookieSource,
                                   hasCapturedCookies: Bool = false) -> Bool {
        !checksum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !mirrors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || cookieSource != .none
            || hasCapturedCookies
    }

    /// The sentence shown when the preview request came back without details.
    static func resolveFailureMessage(host: String?, reason: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, !host.isEmpty else { return reason }
        // The engine's generic note already opens with this; don't say it twice.
        if reason.hasPrefix("Couldn’t reach") || reason.isEmpty {
            return L10n.t("Couldn’t reach %@.", host)
                + (reason.isEmpty ? "" : " " + L10n.t("It may still work when you start."))
        }
        return L10n.t("Couldn’t get details from %1$@. %2$@", host, reason)
    }
}

/// Name validation shared by the SFTP browser's New Folder and Rename prompts.
enum RemoteNameInput {
    static var defaultFolderName: String { L10n.t("untitled folder") }

    /// Finder refuses an empty or whitespace-only name, and so do we: the button stays disabled.
    static func isAcceptable(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Why the SFTP connection editor's Save is disabled, in one sentence; `nil` when it can save.
enum SFTPConnectionForm {
    static func saveBlocker(host: String, username: String, portIsValid: Bool) -> String? {
        let missingHost = host.isEmpty
        let missingUser = username.isEmpty
        switch (missingHost, missingUser) {
        case (true, true): return L10n.t("Enter a host and username to save.")
        case (true, false): return L10n.t("Enter a host to save.")
        case (false, true): return L10n.t("Enter a username to save.")
        case (false, false):
            return portIsValid ? nil : L10n.t("Fix the port to save.")
        }
    }
}
