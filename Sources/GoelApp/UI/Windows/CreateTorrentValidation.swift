import Foundation
import GoelCore

/// Inline checks for the Create Torrent form: which tracker and web-seed lines are unusable, and
/// whether a Private torrent has anywhere to find peers. Pure, so it is tested without a window.
enum CreateTorrentValidation {

    /// A line the form rejects, 1-based as the user counts.
    struct Issue: Equatable {
        let line: Int
        let text: String
    }

    static func trackerIssues(_ text: String) -> [Issue] {
        issues(in: text) { TrackerList.isValidAnnounceURL($0) }
    }

    /// Web seeds must be http(s) with a host; the field also takes commas and spaces between URLs.
    static func webSeedIssues(_ text: String) -> [Issue] {
        issues(in: text, separators: [" ", ",", "\t"]) { raw in
            guard let components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = components.host, !host.isEmpty else { return false }
            return true
        }
    }

    /// A Private torrent finds peers only through trackers (no DHT, PeX or local discovery).
    static func privateNeedsTrackers(isPrivate: Bool, trackers: String) -> Bool {
        isPrivate && TrackerList.parse(trackers).isEmpty
    }

    /// Why Create must stay disabled, or nil when the form is fine.
    static func blocker(isPrivate: Bool, trackers: String, webSeeds: String) -> String? {
        if privateNeedsTrackers(isPrivate: isPrivate, trackers: trackers) {
            return L10n.t("A private torrent needs at least one tracker.")
        }
        if !trackerIssues(trackers).isEmpty { return L10n.t("Fix the tracker URLs to create.") }
        if !webSeedIssues(webSeeds).isEmpty { return L10n.t("Fix the web seed URLs to create.") }
        return nil
    }

    private static func issues(in text: String, separators: Set<Character> = [],
                               isValid: (String) -> Bool) -> [Issue] {
        var out: [Issue] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let pieces = separators.isEmpty
                ? [String(line)]
                : line.split(whereSeparator: { separators.contains($0) }).map(String.init)
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !isValid(trimmed) { out.append(Issue(line: index + 1, text: trimmed)) }
            }
        }
        return out
    }
}
