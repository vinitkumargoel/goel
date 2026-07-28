import Foundation

/// The words the app shows that `Scripts/extract-l10n-keys.py` cannot find on its own.
///
/// Most `L10n.t` call sites pass a literal, so the generator reads the key straight out of the
/// source. A few pass a value instead — `L10n.t(task.priority.displayName)`,
/// `L10n.t(pane.rawValue)` — and the generator has no way to know what those evaluate to. Left
/// alone, the app's most-visible vocabulary (every status, every tab, every settings pane) would
/// be exactly the part missing from the file a translator is handed, which is why the shipped
/// German table translates "Paused" and "Completed" but not "Downloading" or "Queued".
///
/// Listing them here as literals puts them in the generated table and under the missing-key audit.
/// Nothing calls `all`; the literals are the point. When an enum gains a case, nothing here breaks
/// automatically — `LocalizationTests.testTranslationsHaveNoKeysTheBaseTableLacks` is what
/// eventually notices, once someone translates the new word.
///
/// Genuinely unenumerable keys stay out: `L10n.t(adapter.type.capitalized)` is a name the OS made
/// up for a network interface at runtime, and no list can anticipate it.
enum LocalizedVocabulary {

    static var all: [String] {
        downloads + browsing + chrome + diagnostics
    }

    /// `DownloadStatus.displayName`, `FilePriority.displayName`, `TorrentTracker.statusLabel`.
    private static var downloads: [String] {
        [
            L10n.t("Queued"), L10n.t("Requesting info"), L10n.t("Downloading"),
            L10n.t("Verifying"), L10n.t("Paused"), L10n.t("Seeding"),
            L10n.t("Completed"), L10n.t("Failed"),

            L10n.t("Skip"), L10n.t("Low"), L10n.t("Normal"), L10n.t("High"),

            L10n.t("Working"), L10n.t("Updating"), L10n.t("Error"), L10n.t("Idle"),
        ]
    }

    /// SFTP transfer verbs and the upload-collision policies.
    private static var browsing: [String] {
        [
            L10n.t("Uploading"), L10n.t("Copying"),
            L10n.t("upload"), L10n.t("download"), L10n.t("copy"),
            L10n.t("From"), L10n.t("To"),

            L10n.t("Overwrite"), L10n.t("Rename"),

            L10n.t("Owner"), L10n.t("Group"), L10n.t("Everyone"),
            L10n.t("read"), L10n.t("write"), L10n.t("execute"),

            L10n.t("Pinned"), L10n.t("Server now"),
        ]
    }

    /// Sort columns, detail tabs, themes, command groups, settings panes.
    private static var chrome: [String] {
        [
            L10n.t("Name"), L10n.t("Size"), L10n.t("Status"), L10n.t("Added"),
            L10n.t("Download speed"), L10n.t("Upload speed"),

            L10n.t("General"), L10n.t("Details"), L10n.t("Progress"),
            L10n.t("Files"), L10n.t("Connections"),

            L10n.t("Frost Light"), L10n.t("Frost Dark"), L10n.t("Dracula"), L10n.t("Nord"),

            L10n.t("Add"), L10n.t("Downloads"), L10n.t("View"), L10n.t("Settings"),
            L10n.t("Where is…"),

            L10n.t("Network"), L10n.t("Aggregation"), L10n.t("Traffic Limits"),
            L10n.t("BitTorrent"), L10n.t("Scheduler"), L10n.t("RSS Feeds"),
            L10n.t("Advanced"), L10n.t("Antivirus"), L10n.t("Browser"),
            L10n.t("Web Access"), L10n.t("Audit Log"), L10n.t("Licence"),
        ]
    }

    /// `NetworkAdapter.SinglePathReason` and `SwarmProxy.Gap` — sentences, not words, but they
    /// reach the screen the same way.
    private static var diagnostics: [String] {
        [
            L10n.t("Aggregation disabled in Settings"),
            L10n.t("Fewer than 2 selected adapters are up"),
            L10n.t("Traffic profile forbids extra connections"),
            L10n.t("Proxy mode blocks multi-path"),
            L10n.t("VPN policy blocks multi-path"),
            L10n.t("Server does not support multi-path ranges"),
            L10n.t("Server rejected multi-path"),
            L10n.t("This protocol does not support aggregation yet"),
            L10n.t("Expensive adapters excluded"),

            L10n.t("The system proxy isn’t applied to the torrent swarm — choose a manual SOCKS5 "
                + "proxy to route peers through it."),
            L10n.t("An HTTP proxy can only carry tracker traffic — peer connections go out directly."),
            L10n.t("The manual proxy is missing a host or port, so the swarm goes out directly."),
        ]
    }
}
