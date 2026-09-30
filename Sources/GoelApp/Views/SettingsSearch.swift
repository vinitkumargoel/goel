import SwiftUI
import GoelCore

extension SettingsView.Pane {

    /// Sidebar sections. The order of `allCases` and of each `panes` list is the display order.
    enum Group: String, CaseIterable, Identifiable {
        case basics = "Basics"
        case transfers = "Transfers"
        case integrations = "Integrations"
        case admin = "Admin"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .basics: return L10n.t("Basics")
            case .transfers: return L10n.t("Transfers")
            case .integrations: return L10n.t("Integrations")
            case .admin: return L10n.t("Admin")
            }
        }

        var panes: [SettingsView.Pane] {
            switch self {
            case .basics: return [.general, .network]
            case .transfers: return [.traffic, .aggregation, .bittorrent, .scheduler, .rss]
            case .integrations: return [.browser, .remote, .antivirus]
            case .admin: return [.advanced, .audit, .license]
            }
        }
    }

    var group: Group {
        Group.allCases.first { $0.panes.contains(self) } ?? .basics
    }

    /// The English source strings (which are also the `L10n` keys) of this pane's title,
    /// subtitle, section headers and `SetRow` titles. Keep in step with the pane when rows move.
    var searchKeywords: [String] {
        switch self {
        case .general:
            return ["Appearance, startup, and where files land.",
                    "Theme", "Language", "Launch at login", "Launch minimized", "Show in menu bar",
                    "Default download folder", "Fixed folder", "When a file exists", "Clipboard capture",
                    "Max video quality", "Media tools", "Download subtitles", "Subtitle languages",
                    "Include auto-captions", "ffmpeg path", "Conversions at once"]
        case .network:
            return ["Proxy, timeouts, retries, and authentication.",
                    "Proxy", "Proxy type", "Proxy host", "Proxy port", "Connection timeout",
                    "Retry count", "Retry interval", "Auto-retry failed downloads", "Auto-retry attempts",
                    "Custom user-agent", "Cookie / auth handling", "Re-download when remote changes",
                    "Network awareness", "Pause on expensive networks", "Pause in Low Data Mode",
                    "Site logins", "Host", "Username", "Password"]
        case .aggregation:
            return ["Multi-path HTTP downloads across network adapters", "Enable multi-path downloads", "Adapters",
                    "Options", "Include expensive networks", "Allow paths outside VPN",
                    "Streams per adapter", "Check path diversity"]
        case .traffic:
            return ["Three switchable profiles. The status-bar snail toggles Unlimited vs the active profile.",
                    "Max download speed", "Max upload speed", "Max connections (global)",
                    "Max connections per server", "Max simultaneous downloads", "Stop seeding at ratio",
                    "Max metadata-resolution downloads", "Additional connections to optimize speed"]
        case .bittorrent:
            return ["Protocol, privacy, and watch-folder behavior.",
                    "Default torrent client", "Auto-delete .torrent when done",
                    "Watch folder for .torrent files", "Watched folder",
                    "Start watched torrents without confirmation", "Encryption mode", "Enable DHT",
                    "Enable PeX", "Enable Local Peer Discovery", "Enable µTP"]
        case .scheduler:
            return ["Download windows, scheduled profiles, and what happens when the queue finishes.",
                    "When downloads finish", "Then", "Download window",
                    "Only download during a daily window", "Start", "End", "Days",
                    "Profile inside the window", "Sleep", "Shut down"]
        case .rss:
            return ["Watch feeds and queue new items automatically (podcasts, releases, torrent feeds).",
                    "Check feeds every", "Feeds", "Add a feed", "Feed URL", "Title contains",
                    "Add items paused"]
        case .advanced:
            return ["Notifications, power management, and backup.",
                    "Notifications", "On download added", "On download completed", "On download failed",
                    "Only when app is inactive", "Play sound", "Power management",
                    "Prevent sleep during active downloads", "Allow sleep if downloads can resume later",
                    "Allow sleep while seeding", "Pause downloads below battery threshold",
                    "Don't seed on battery", "Post-download actions", "Auto-extract archives",
                    "Run a script on completion", "Script path", "Arguments", "Backup",
                    "Periodically back up the download list", "Backup interval", "Keep", "Updates",
                    "Check for updates automatically", "Release feed URL", "Diagnostics", "Support report"]
        case .antivirus:
            return ["Run an external scanner on finished files. Optional, low priority on macOS.",
                    "Scan finished files", "Scanner", "Executable path", "Argument template"]
        case .browser:
            return ["Browser Integration", "Chrome, Edge, Brave & Firefox", "1. Install the messaging helper",
                    "2. Load the extension", "3. Restart the browser", "4. Capture",
                    "1. Open Safari’s extensions", "2. Turn it on", "3. Capture", "What Safari can’t do",
                    "Help", "Full instructions", "Without the extension", "URL scheme", "Bookmarklet",
                    "Services menu", "Drop basket"]
        case .remote:
            return ["Enable web portal", "Port", "Require sign-in", "Username", "Password",
                    "Allow access from the network", "Read-only mode", "Session timeout", "Web theme",
                    "API token", "Open portal", "Hardening", "Serve over HTTPS", "Identity (.p12) path",
                    "Extra host names", "Failed sign-ins before backoff", "Backoff (seconds)",
                    "Single sign-on (advanced)", "Trust a proxy’s identity header", "Header name",
                    "Trusted proxies", "Scan from your phone", "Web access is not running"]
        case .audit:
            return ["Keep an audit log", "Folder", "Rotate at (MB)", "Rotated files to keep",
                    "Keep for (days)", "Reveal in Finder"]
        case .license:
            return ["Using Goel° at work?", "What this app never does", "For your own records",
                    "Licensed to", "Licence reference"]
        }
    }
}

/// Filters the Settings sidebar against a static keyword index. Matching is case- and
/// diacritic-insensitive, and every word of the query must appear (in any order) in one keyword.
enum SettingsSearch {

    /// Fewer characters than this don't highlight rows: one letter lights up half the pane.
    static let minimumHighlightLength = 2

    static func isActive(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The query's words, folded once so each keyword costs only a substring check.
    static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    }

    static func matches(_ text: String, query: String) -> Bool {
        matches(folded: fold(text), tokens: tokens(query))
    }

    static func matches(folded text: String, tokens: [String]) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy { text.contains($0) }
    }

    /// Whether a `SetRow` titled `name` lights up for this query.
    static func highlights(_ name: String, query: String) -> Bool {
        guard !name.isEmpty,
              query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumHighlightLength
        else { return false }
        return matches(name, query: query)
    }

    /// What VoiceOver hears when the results change.
    static func resultAnnouncement(count: Int) -> String {
        switch count {
        case 0: return L10n.t("No settings match")
        case 1: return L10n.t("1 pane matches")
        default: return L10n.t("%d panes match", count)
        }
    }

    /// A pane matches when its name or any keyword does, in English or in the UI language.
    /// An empty query matches everything, in sidebar order.
    static func panes(matching query: String) -> [SettingsView.Pane] {
        index(for: L10n.currentLanguage).panes(matching: query)
    }

    /// Builds a throwaway index with `localize`; for tests and one-off lookups.
    static func panes(matching query: String, localize: (String) -> String) -> [SettingsView.Pane] {
        Index(localize: localize).panes(matching: query)
    }

    /// Every pane's keywords, folded, in English and in one UI language.
    struct Index {
        let entries: [(pane: SettingsView.Pane, keys: [String])]

        init(localize: (String) -> String) {
            entries = SettingsView.Pane.Group.allCases.flatMap(\.panes).map { pane in
                let english = [pane.rawValue] + pane.searchKeywords
                var keys: [String] = []
                var seen = Set<String>()
                for key in english {
                    for folded in [SettingsSearch.fold(key), SettingsSearch.fold(localize(key))]
                    where seen.insert(folded).inserted {
                        keys.append(folded)
                    }
                }
                return (pane, keys)
            }
        }

        func panes(matching query: String) -> [SettingsView.Pane] {
            guard SettingsSearch.isActive(query) else { return entries.map(\.pane) }
            let tokens = SettingsSearch.tokens(query)
            return entries
                .filter { entry in entry.keys.contains { SettingsSearch.matches(folded: $0, tokens: tokens) } }
                .map(\.pane)
        }
    }

    private static let cacheLock = NSLock()
    private static var cached: (language: String, index: Index)?

    /// Built once per UI language: switching language rebuilds it, typing never does.
    static func index(for language: String) -> Index {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, cached.language == language { return cached.index }
        let index = Index { L10n.string($0, language: language) }
        cached = (language, index)
        return index
    }
}

private struct SettingsSearchQueryKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    /// The Settings search text, so a `SetRow` whose title matches can highlight itself.
    var settingsSearchQuery: String {
        get { self[SettingsSearchQueryKey.self] }
        set { self[SettingsSearchQueryKey.self] = newValue }
    }
}
