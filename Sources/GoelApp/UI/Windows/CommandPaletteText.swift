import Foundation
import GoelCore

/// The palette's fixed text: what each settings pane holds, the words that find it, and the
/// AppleScript sample.
enum CommandPaletteText {

    static let appleScriptExample = """
    tell application "Goel°"
        add download "https://example.com/file.zip"
        count downloads
    end tell
    """

    static func paneSummary(_ pane: SettingsView.Pane) -> String {
        switch pane {
        case .general:     return L10n.t("Theme, language, default folder, clipboard capture, sleep")
        case .rules:       return L10n.t("Sort new downloads into folders, tags and limits by name, site or size")
        case .notifications: return L10n.t("Banners for added, finished and failed downloads")
        case .network:     return L10n.t("Proxy, timeouts, retries, saved per-host credentials")
        case .aggregation: return L10n.t("Combine Wi-Fi and Ethernet on one download")
        case .traffic:     return L10n.t("Three switchable speed and connection profiles")
        case .bittorrent:  return L10n.t("DHT, PeX, encryption, and the .torrent watch folder")
        case .scheduler:   return L10n.t("Daily download window and what happens when the queue drains")
        case .rss:         return L10n.t("Watch feeds and queue matching items automatically")
        case .afterDownload: return L10n.t("Unpack archives and run a script when a download finishes")
        case .media:       return L10n.t("Stream quality, subtitles, ffmpeg conversions")
        case .backup:      return L10n.t("Back up the download list and check for updates")
        case .diagnostics: return L10n.t("A redacted support report to copy or export")
        case .antivirus:   return L10n.t("Run an external scanner over finished files")
        case .browser:     return L10n.t("The extension, the helper, the bookmarklet, the URL scheme")
        case .remote:      return L10n.t("Reach your queue from a phone or another machine")
        case .audit:       return L10n.t("Local, on-disk record of what was downloaded")
        case .license:     return L10n.t("Personal use, commercial licensing, and what the app never does")
        }
    }

    static func paneKeywords(_ pane: SettingsView.Pane) -> [String] {
        switch pane {
        case .general:     return ["theme", "folder", "language", "clipboard", "sleep", "battery", "power"]
        case .rules:       return ["rules", "sort", "auto", "filter", "folder", "category", "when done"]
        case .notifications: return ["notifications", "banner", "alert", "sound", "notify"]
        case .network:     return ["proxy", "socks", "timeout", "retry", "user agent", "credentials", "password"]
        case .aggregation: return ["aggregation", "multipath", "wifi", "ethernet", "adapter", "bonding"]
        case .traffic:     return ["speed", "limit", "throttle", "connections", "seed ratio", "profile"]
        case .bittorrent:  return ["torrent", "dht", "pex", "encryption", "watch folder", "magnet", "seeding"]
        case .scheduler:   return ["schedule", "window", "night", "shutdown", "sleep", "quit"]
        case .rss:         return ["rss", "feed", "atom", "podcast", "auto download", "subscribe"]
        case .afterDownload: return ["script", "extract", "unzip", "archive", "post-download", "automation"]
        case .media:       return ["ffmpeg", "subtitles", "video", "quality", "hls", "convert", "audio"]
        case .backup:      return ["backup", "restore", "updates", "sparkle", "release"]
        case .diagnostics: return ["diagnostics", "support", "bug report", "logs"]
        case .antivirus:   return ["antivirus", "scan", "clamav", "virus", "malware"]
        case .browser:     return ["browser", "extension", "chrome", "firefox", "safari", "bookmarklet", "capture"]
        case .remote:      return ["remote", "web", "portal", "phone", "lan", "tls", "server"]
        case .audit:       return ["audit", "log", "compliance", "record", "retention"]
        case .license:     return ["licence", "license", "commercial", "work", "business", "polyform", "legal"]
        }
    }
}
