import SwiftUI
import GoelCore

extension SettingsView.Pane {

    /// Sidebar sections. The order of `allCases` and of each `panes` list is the display order.
    enum Group: String, CaseIterable, Identifiable {
        case basics = "Basics"
        case transfers = "Transfers"
        case afterDownload = "After download"
        case integrations = "Integrations"
        case admin = "Admin"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .basics: return L10n.t("Basics")
            case .transfers: return L10n.t("Transfers")
            case .afterDownload: return L10n.t("After download")
            case .integrations: return L10n.t("Integrations")
            case .admin: return L10n.t("Admin")
            }
        }

        var panes: [SettingsView.Pane] {
            switch self {
            case .basics: return [.general, .rules, .notifications, .network]
            case .transfers: return [.traffic, .bittorrent, .scheduler, .rss, .aggregation]
            case .afterDownload: return [.afterDownload, .antivirus, .media]
            case .integrations: return [.browser, .remote]
            case .admin: return [.backup, .audit, .diagnostics, .license]
            }
        }
    }

    var group: Group {
        Group.allCases.first { $0.panes.contains(self) } ?? .basics
    }

    /// The English source strings (which are also the `L10n` keys) of this pane's title,
    /// subtitle, card titles and `SettingRow` titles. Keep in step with the pane when rows move.
    var searchKeywords: [String] {
        switch self {
        case .general:
            return ["Appearance, startup, where files land, and sleep.",
                    "Appearance", "Theme", "Light", "Dark", "Language", "Startup", "Launch at login",
                    "Launch minimized", "Show in menu bar",
                    "Default download folder", "Fixed folder", "Choose automatically, by type, by source URL, or fixed.", "When a file exists", "Clipboard capture",
                    "Power management", "Prevent sleep during active downloads",
                    "Allow sleep if downloads can resume later", "Allow sleep while seeding",
                    "Pause downloads below battery threshold", "Don’t seed on battery"]
        case .rules:
            return ["Rules", "Sort new downloads by name, type, site or size.", "Download rules",
                    "Add Rule…", "Download rule", "When a new download matches", "Speed cap (KB/s)",
                    "Start paused", "When done", "Tag"]
        case .notifications:
            return ["Which events show a banner, and whether macOS lets them through.",
                    "Permission", "Send Test", "Notify me", "On download added", "On download completed",
                    "On download failed", "Only when app is inactive", "Play sound"]
        case .media:
            return ["Stream quality, subtitles, and ffmpeg conversions.",
                    "Streams", "Max video quality", "Subtitles", "Download subtitles", "Subtitle languages",
                    "Include auto-captions", "Conversions", "ffmpeg path", "Conversions at once"]
        case .network:
            return ["Proxy, timeouts, retries, and authentication.",
                    "Proxy", "Proxy type", "Proxy host", "Proxy port", "Connection timeout",
                    "Retry count", "Retry interval", "Auto-retry failed downloads", "Auto-retry attempts",
                    "Custom user-agent", "Cookie / auth handling", "Re-download when remote changes",
                    "Connections", "Network awareness", "Pause on expensive networks",
                    "Pause in Low Data Mode"]
        case .aggregation:
            return ["Multi-path HTTP downloads across network adapters", "Aggregation",
                    "Enable multi-path downloads", "Adapters",
                    "Options", "How it works", "Include expensive networks", "Allow paths outside VPN",
                    "Streams per adapter", "Check path diversity"]
        case .traffic:
            return ["Three switchable speed profiles. The status-bar speed toggle switches between Unlimited and the active profile.",
                    "Max download speed", "Max upload speed", "Max connections (global)",
                    "Max connections per server", "Max simultaneous downloads", "0 = unlimited.",
                    "Seeding and peer uploads. 0 = unlimited.", "Stop seeding at ratio",
                    "Max metadata-resolution downloads", "Extra connections per download"]
        case .bittorrent:
            return ["Protocol, privacy, and watch-folder behavior.",
                    "Torrent files", "Peers & privacy", "Extra trackers", "Default torrent client",
                    "Auto-delete .torrent when done",
                    "Watch folder for .torrent files", "Watched folder",
                    "Start watched torrents without confirmation", "Encryption mode", "Enable DHT",
                    "Enable PeX", "Enable Local Peer Discovery", "Enable µTP",
                    "Append trackers from a list", "Tracker list URL"]
        case .scheduler:
            return ["Download windows, scheduled profiles, and what happens when the queue finishes.",
                    "When downloads finish", "Then", "Download window",
                    "Only download during a daily window", "Start", "End", "Days",
                    "Profile inside the window", "Sleep", "Shut down",
                    "Weekly profile schedule", "Switch profiles by the hour"]
        case .rss:
            return ["Watch feeds and queue new items automatically (podcasts, releases, torrent feeds).",
                    "Check feeds every", "Feeds", "Add a feed", "Feed URL", "Title contains",
                    "Add items paused", "Rules and articles"]
        case .afterDownload:
            return ["What happens to a file once it finishes.",
                    "Extract", "Auto-extract archives", "Script", "Run a script on completion",
                    "Script path", "Arguments"]
        case .backup:
            return ["Keep a copy of the download list, and keep the app current.",
                    "Backup", "Periodically back up the download list", "Backup interval", "Keep",
                    "Updates", "Check for updates automatically", "Release feed URL", "Check Now"]
        case .diagnostics:
            return ["A support report you can read before you share it.", "Support report"]
        case .antivirus:
            return ["Run an external scanner on finished files. Optional, low priority on macOS.",
                    "Scan finished files", "Scanner", "Executable path", "Argument template"]
        case .browser:
            return ["Browser Integration", "Your browsers", "Safari", "Chrome, Edge, Brave & Firefox",
                    "1. Install the messaging helper",
                    "2. Load the extension", "3. Restart the browser", "4. Capture",
                    "1. Open Safari’s extensions", "2. Turn it on", "3. Capture", "What Safari can’t do",
                    "Help", "Full instructions", "Without the extension", "URL scheme", "Bookmarklet",
                    "Services menu", "Drop basket", "Site logins", "Host", "Username", "Password"]
        case .remote:
            return ["Portal", "Enable web portal", "Port", "Access", "Theme & API", "Require sign-in", "Username",
                    "Password",
                    "Allow access from the network", "Read-only mode", "Session timeout", "Web theme",
                    "API token", "Open portal", "Hardening", "Serve over HTTPS", "Identity (.p12) path",
                    "Extra host names", "Failed sign-ins before backoff", "Backoff (seconds)",
                    "Single sign-on (advanced)", "Trust a proxy’s identity header", "Header name",
                    "Trusted proxies", "Scan from your phone", "Web access is not running"]
        case .audit:
            return ["Keep an audit log", "Rotation", "Folder", "Rotate at (MB)", "Rotated files to keep",
                    "Keep for (days)", "Reveal in Finder"]
        case .license:
            return ["Using Goel° at work?", "What this app never does", "For your own records",
                    "Licensed to", "Licence reference"]
        }
    }
}

/// Filters the Settings sidebar against a static keyword index. Matching is case- and
/// diacritic-insensitive, and every word of the query must appear (in any order, or as a synonym) in some keyword of the
/// pane; a pane with one keyword holding every word ranks first.
enum SettingsSearch {

    /// Fewer characters than this don't highlight rows: one letter lights up half the pane.
    static let minimumHighlightLength = 2

    static func isActive(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Words that mean the same thing to a user hunting for a setting. Each group is matched
    /// as alternatives: a query word hits a keyword containing any member. Multi-word members
    /// are folded to their first word in the query ("dark mode" → "dark").
    static let synonymGroups: [[String]] = [
        ["limit", "throttle", "bandwidth", "cap", "max", "unlimited"],
        ["dark", "light", "appearance", "theme"],
        ["location", "folder", "save", "directory"],
        ["shutdown", "shut down", "power off"],
    ]

    /// Phrases collapsed to one query word before splitting ("dark mode" is one idea).
    private static let phrases: [(phrase: String, word: String)] = [
        ("dark mode", "dark"), ("light mode", "light"), ("speed limit", "limit"),
    ]

    /// Folds spaces and hyphens away so "shutdown" meets "Shut down" and "Pre-fetch" meets "prefetch".
    static func squeeze(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "-" && $0 != "‑" }
    }

    /// The query's words, folded once so each keyword costs only a substring check.
    static func tokens(_ query: String) -> [String] {
        var folded = fold(query)
        for (phrase, word) in phrases { folded = folded.replacingOccurrences(of: phrase, with: word) }
        return folded.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The query word plus its synonyms, squeezed for comparison.
    private static func alternatives(_ token: String) -> [String] {
        let squeezed = squeeze(token)
        var out = [squeezed]
        for group in synonymGroups where group.contains(where: { squeeze($0) == squeezed }) {
            out += group.map(squeeze)
        }
        return out
    }

    /// Whether `text` (already folded) contains the token or a synonym of it.
    static func contains(folded text: String, token: String) -> Bool {
        if text.contains(token) { return true }
        let squeezed = squeeze(text)
        return alternatives(token).contains { squeezed.contains($0) }
    }

    static func matches(_ text: String, query: String) -> Bool {
        matches(folded: fold(text), tokens: tokens(query))
    }

    /// Every token must hit this one text.
    static func matches(folded text: String, tokens: [String]) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy { contains(folded: text, token: $0) }
    }

    /// Whether a `SettingRow` titled `name` lights up for this query.
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

    /// Individual rows, not whole panes, for the command palette: "sleep" should land on
    /// "Prevent sleep during active downloads", not on a list of three panes. Sentences (pane
    /// subtitles) are left out; each row carries its localized title.
    static func rows(matching query: String, limit: Int = 6,
                     localize: (String) -> String = { L10n.t($0) }) -> [(pane: SettingsView.Pane, title: String)] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumHighlightLength else { return [] }
        let tokens = tokens(query)
        var out: [(SettingsView.Pane, String)] = []
        for pane in SettingsView.Pane.Group.allCases.flatMap(\.panes) {
            for key in pane.searchKeywords where !key.hasSuffix(".") {
                let title = localize(key)
                guard matches(folded: fold(title), tokens: tokens) || matches(folded: fold(key), tokens: tokens)
                else { continue }
                out.append((pane, title))
                if out.count == limit { return out }
            }
        }
        return out
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
            let hits = entries
                .compactMap { entry -> (pane: SettingsView.Pane, strict: Bool)? in
                    if entry.keys.contains(where: { SettingsSearch.matches(folded: $0, tokens: tokens) }) {
                        return (entry.pane, true)
                    }
                    let loose = tokens.allSatisfy { token in
                        entry.keys.contains { SettingsSearch.contains(folded: $0, token: token) }
                    }
                    return loose ? (entry.pane, false) : nil
                }
            // Panes where one keyword has every word come first; the rest follow in sidebar order.
            return hits.filter(\.strict).map(\.pane) + hits.filter { !$0.strict }.map(\.pane)
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
    /// The Settings search text, so a `SettingRow` whose title matches can highlight itself.
    var settingsSearchQuery: String {
        get { self[SettingsSearchQueryKey.self] }
        set { self[SettingsSearchQueryKey.self] = newValue }
    }
}
