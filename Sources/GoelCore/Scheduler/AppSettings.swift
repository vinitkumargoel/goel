import Foundation

/// User-facing, persistable configuration that drives the scheduler.
///
/// It holds the list of switchable traffic profiles, which one is active, the
/// "snail" speed-limit toggle (when **off**, byte/sec caps are lifted — i.e.
/// unlimited speed — while the connection/simultaneous limits still apply), and
/// the default save folder used when a download is added without an explicit one.
/// It also carries the General/Network/BitTorrent/Notification/Power/Backup/
/// Antivirus preferences surfaced in the Settings window so every pane survives
/// relaunch and can be re-applied to the engines.
///
/// It is a plain value type so it can be copied, diffed, encoded to disk, and
/// safely handed across isolation boundaries.
///
/// Enum-like fields (theme, proxy mode, folder rule, encryption mode, …) are
/// stored as plain `String` rather than typed enums because this type lives in
/// `GoelCore` and must not depend on the app layer's `AppTheme`/picker types.
public struct AppSettings: Codable, Sendable, Hashable {

    // MARK: Traffic

    /// All selectable profiles (defaults to Low / Medium / High).
    public var profiles: [TrafficProfile]

    /// The `name` of the currently selected profile.
    public var selectedProfileName: String

    /// The "snail" flag. When `false`, speed limiting is disabled and the
    /// effective profile reports unlimited download/upload byte rates.
    public var speedLimitEnabled: Bool

    /// Where new downloads are saved when no directory is supplied.
    public var defaultSaveDirectory: String

    // MARK: General

    /// Color-scheme preference: `system` | `light` | `dark`.
    public var theme: String

    /// UI language (English to start; structured for localization).
    public var language: String

    /// Register the app as a login item so it starts when the user logs in.
    public var launchAtLogin: Bool

    /// Open to the menu bar instead of a window on launch.
    public var launchMinimized: Bool

    /// Show the menu-bar status item — a compact popover with live ↓/↑ speed and
    /// quick controls (the "Rich list" menu-bar concept).
    public var menuBarExtraEnabled: Bool

    /// How the default save folder is chosen: `automatic` | `byType` |
    /// `bySource` | `fixed`.
    public var defaultFolderRule: String

    /// What to do when a file with the target name already exists at add time:
    /// `overwrite` (truncate and replace), `rename` (append ` (n)` to keep both),
    /// or `skip` (don't add the download).
    public var existingFileReaction: String

    /// Watch the clipboard and offer to add copied http(s)/magnet links.
    public var clipboardMonitorEnabled: Bool

    /// Preferred maximum video height for HLS streams (0 = best available).
    /// The grabber picks the highest-bandwidth rendition at or below this height.
    public var hlsMaxHeight: Int

    /// Where the detail panel is docked: `right` (side edge) | `bottom`. Stored as
    /// a plain `String` (like ``theme``) so the app-layer enum stays out of core.
    public var detailPanelPosition: String

    // MARK: Network

    /// Proxy selection: `none` | `system` | `manual`.
    public var proxyMode: String

    /// The manual proxy's protocol: `http` (default) | `socks5`. Applies to
    /// HTTP/HTTPS downloads (the SOCKS hop tunnels both schemes).
    public var proxyType: String

    /// Reserved: route FTP/SFTP/BitTorrent through the manual proxy too. Not yet
    /// wired to those engines (their transports need proxy support in the native
    /// shims), so it is intentionally not surfaced in the UI. Persisted so the
    /// setting survives once that follow-up lands.
    public var proxyAllProtocols: Bool

    /// Manual proxy host (used only when ``proxyMode`` is `manual`).
    public var proxyHost: String

    /// Manual proxy port (used only when ``proxyMode`` is `manual`).
    public var proxyPort: Int

    /// Per-request connection timeout, in seconds.
    public var connectionTimeout: Double

    /// How many times a failed transfer is retried.
    public var retryCount: Int

    /// Seconds to wait between retries.
    public var retryInterval: Double

    /// Automatically re-queue a whole download that has *failed* and try it
    /// again — up to ``autoRetryMaxAttempts`` times, waiting an exponentially
    /// growing delay between attempts. Distinct from ``retryCount`` (the HTTP
    /// engine's per-request budget within a single run). Off by default.
    public var autoRetryEnabled: Bool

    /// How many times a failed download is auto-retried before it is left in the
    /// failed state for a manual retry. Only used when ``autoRetryEnabled``.
    public var autoRetryMaxAttempts: Int

    /// User-Agent header sent with HTTP requests.
    public var userAgent: String

    /// Reuse cookies for protected downloads.
    public var cookieAuthEnabled: Bool

    // MARK: BitTorrent

    /// Register GoelDownloader as the default `.torrent`/magnet handler.
    public var btMakeDefaultClient: Bool

    /// Delete the source `.torrent` file once the download completes.
    public var btAutoDeleteTorrent: Bool

    /// Watch a folder and auto-add any `.torrent` files dropped into it.
    public var btWatchFolderEnabled: Bool

    /// Folder watched when ``btWatchFolderEnabled`` is on.
    public var btWatchFolderPath: String

    /// Start watched torrents without asking for confirmation.
    public var btWatchStartWithoutConfirmation: Bool

    /// Protocol encryption policy: `prefer` | `require` | `disable`.
    public var btEncryptionMode: String

    /// Enable the distributed hash table for peer discovery.
    public var btEnableDHT: Bool

    /// Enable peer exchange.
    public var btEnablePeX: Bool

    /// Enable local peer discovery on the LAN.
    public var btEnableLPD: Bool

    /// Enable the micro transport protocol (µTP).
    public var btEnableUTP: Bool

    // MARK: Notifications

    /// Notify when a download is added.
    public var notifyOnAdded: Bool

    /// Notify when a download completes.
    public var notifyOnCompleted: Bool

    /// Notify when a download fails.
    public var notifyOnFailed: Bool

    /// Only post notifications while the app is inactive/backgrounded.
    public var notifyOnlyWhenInactive: Bool

    /// Play a sound with notifications.
    public var notificationSound: Bool

    // MARK: Power

    /// Prevent the Mac from sleeping while downloads are active.
    public var preventSleepWhileDownloading: Bool

    /// Allow sleep when active downloads can be resumed later.
    public var allowSleepIfResumable: Bool

    /// Allow sleep while only seeding (no active downloads).
    public var allowSleepWhileSeeding: Bool

    /// Pause downloads when the battery drops below ``batteryThresholdPercent``.
    public var pauseBelowBatteryThreshold: Bool

    /// Battery percentage below which downloads pause.
    public var batteryThresholdPercent: Int

    /// Never seed while running on battery power.
    public var dontSeedOnBattery: Bool

    // MARK: Backup

    /// Periodically back up the download list.
    public var backupEnabled: Bool

    /// Hours between automatic backups.
    public var backupIntervalHours: Int

    // MARK: Antivirus

    /// Scan finished files with an external antivirus before marking them done.
    public var antivirusEnabled: Bool

    /// Human-readable scanner name shown in the picker.
    public var antivirusScanner: String

    /// Path to the antivirus executable.
    public var antivirusExecutablePath: String

    /// Argument template; `%path%` is replaced with the scanned file path.
    public var antivirusArgumentTemplate: String

    // MARK: Queue automation

    /// What to do once the last download finishes: `none` | `quit` | `sleep` |
    /// `shutdown`. One-shot — the app resets it to `none` after firing so a
    /// forgotten toggle can't shut the Mac down days later.
    public var autoShutdownAction: String

    /// Only download inside a daily time window (pause active tasks outside it).
    public var scheduleEnabled: Bool

    /// Window start, minutes after midnight (e.g. 1320 = 22:00).
    public var scheduleStartMinute: Int

    /// Window end, minutes after midnight. An end before the start wraps past
    /// midnight (22:00 → 07:00).
    public var scheduleEndMinute: Int

    /// Weekdays the window applies to (Calendar convention, 1 = Sunday … 7 =
    /// Saturday). Days not listed behave as outside the window.
    public var scheduleDays: [Int]

    /// Traffic profile to activate while inside the window ("" = keep current).
    public var scheduleProfileName: String

    // MARK: Network awareness

    /// Pause downloads on expensive interfaces (personal hotspot).
    public var pauseOnExpensiveNetwork: Bool

    /// Pause downloads when the system is in Low Data Mode.
    public var pauseOnConstrainedNetwork: Bool

    // MARK: Post-download actions

    /// Auto-extract recognised archives (.zip) next to the download when it
    /// completes.
    public var postDownloadExtractArchives: Bool

    /// Run a user script after each completed download.
    public var postDownloadScriptEnabled: Bool

    /// Script/executable to run; receives the finished file path via `%path%`
    /// in ``postDownloadScriptArgs``.
    public var postDownloadScriptPath: String

    /// Argument template for the post-download script.
    public var postDownloadScriptArgs: String

    // MARK: Media tools

    /// After a finished HTTP task's remote resource changes (ETag/Last-Modified/
    /// size), automatically re-download it. Off by default — a deliberate opt-in
    /// so a finished file is never silently replaced.
    public var autoRedownloadOnRemoteChange: Bool

    /// Download subtitles alongside yt-dlp video downloads.
    public var subtitleDownloadEnabled: Bool

    /// Comma/space separated subtitle language codes to fetch (e.g. "en, es").
    public var subtitleLanguages: String

    /// Include machine-generated (auto) captions when no human subtitles exist.
    public var subtitleIncludeAutoGenerated: Bool

    /// Explicit path to an `ffmpeg` binary for Convert / Extract-audio. Empty ⇒
    /// auto-detect on PATH / common Homebrew locations. No binary is bundled.
    public var ffmpegPath: String

    // MARK: Remote access

    /// Serve the remote-control web UI / JSON API.
    public var remoteAccessEnabled: Bool

    /// TCP port the embedded server listens on.
    public var remotePort: Int

    /// Bearer token remote clients must present. Generated when enabling.
    public var remoteToken: String

    /// Listen on all interfaces (LAN) instead of localhost only.
    public var remoteAllowLAN: Bool

    /// Require a username + password sign-in for the web portal (recommended).
    /// When off, anyone who can reach the port has full control — only sane on a
    /// loopback bind. The bearer ``remoteToken`` still works for scripts either way.
    public var remoteRequireAuth: Bool

    /// The web portal login username.
    public var remoteUsername: String

    /// The web portal password, stored as a versioned salted-iterated hash
    /// (`"v1$saltHex$hashHex"`) — never plaintext. Empty means "no password set".
    /// Written by the app via ``RemotePassword/hash(_:)``; verified server-side.
    public var remotePasswordHash: String

    /// Serve the portal read-only: clients can view/stream but not add, remove,
    /// pause, or change anything. Useful for a shared or exposed link.
    public var remoteReadOnly: Bool

    /// How long a web session cookie stays valid before re-login, in minutes.
    public var remoteSessionMinutes: Int

    /// The web portal's theme, as an ``AppTheme`` token (e.g. `"frost-dark"`).
    /// Deliberately **independent** of ``theme`` (the local app look): changing
    /// one never touches the other, so the desktop and the browser can each run
    /// their own appearance. Persisted here so it survives relaunch and is the
    /// default a fresh browser adopts.
    public var remoteTheme: String

    // MARK: RSS auto-download

    /// Feeds watched for new items to queue automatically.
    public var rssFeeds: [RSSFeed]

    /// Minutes between feed refreshes.
    public var rssPollIntervalMinutes: Int

    // MARK: Backup retention

    /// How many timestamped backups to keep before pruning the oldest.
    public var backupKeepCount: Int

    // MARK: Updates

    /// Check for new releases periodically (manual check always available).
    public var autoCheckUpdates: Bool

    /// Override the release feed URL ("" = the built-in GitHub releases feed).
    public var updateFeedURL: String

    public init(
        profiles: [TrafficProfile] = TrafficProfile.defaults,
        selectedProfileName: String = TrafficProfile.medium.name,
        speedLimitEnabled: Bool = true,
        defaultSaveDirectory: String = AppSettings.systemDownloadsDirectory,
        // General
        theme: String = "frost-dark",
        language: String = "English",
        launchAtLogin: Bool = false,
        launchMinimized: Bool = false,
        menuBarExtraEnabled: Bool = true,
        defaultFolderRule: String = "fixed",
        existingFileReaction: String = "rename",
        clipboardMonitorEnabled: Bool = false,
        hlsMaxHeight: Int = 0,
        detailPanelPosition: String = "right",
        // Network
        proxyMode: String = "none",
        proxyType: String = "http",
        proxyAllProtocols: Bool = false,
        proxyHost: String = "",
        proxyPort: Int = 0,
        connectionTimeout: Double = 30,
        retryCount: Int = 3,
        retryInterval: Double = 5,
        autoRetryEnabled: Bool = false,
        autoRetryMaxAttempts: Int = 5,
        userAgent: String = "GoelDownloader/1.0 (macOS)",
        cookieAuthEnabled: Bool = true,
        // BitTorrent
        btMakeDefaultClient: Bool = false,
        btAutoDeleteTorrent: Bool = false,
        btWatchFolderEnabled: Bool = false,
        btWatchFolderPath: String = "",
        btWatchStartWithoutConfirmation: Bool = false,
        btEncryptionMode: String = "prefer",
        btEnableDHT: Bool = true,
        btEnablePeX: Bool = true,
        btEnableLPD: Bool = true,
        btEnableUTP: Bool = true,
        // Notifications
        notifyOnAdded: Bool = false,
        notifyOnCompleted: Bool = true,
        notifyOnFailed: Bool = true,
        notifyOnlyWhenInactive: Bool = false,
        notificationSound: Bool = true,
        // Power
        preventSleepWhileDownloading: Bool = true,
        allowSleepIfResumable: Bool = false,
        allowSleepWhileSeeding: Bool = false,
        pauseBelowBatteryThreshold: Bool = false,
        batteryThresholdPercent: Int = 20,
        dontSeedOnBattery: Bool = false,
        // Backup
        backupEnabled: Bool = false,
        backupIntervalHours: Int = 24,
        // Antivirus
        antivirusEnabled: Bool = false,
        antivirusScanner: String = "",
        antivirusExecutablePath: String = "",
        antivirusArgumentTemplate: String = "%path%",
        // Queue automation
        autoShutdownAction: String = "none",
        scheduleEnabled: Bool = false,
        scheduleStartMinute: Int = 22 * 60,
        scheduleEndMinute: Int = 7 * 60,
        scheduleDays: [Int] = [1, 2, 3, 4, 5, 6, 7],
        scheduleProfileName: String = "",
        // Network awareness
        pauseOnExpensiveNetwork: Bool = false,
        pauseOnConstrainedNetwork: Bool = false,
        // Post-download actions
        postDownloadExtractArchives: Bool = false,
        postDownloadScriptEnabled: Bool = false,
        postDownloadScriptPath: String = "",
        postDownloadScriptArgs: String = "%path%",
        // Media tools
        autoRedownloadOnRemoteChange: Bool = false,
        subtitleDownloadEnabled: Bool = false,
        subtitleLanguages: String = "en",
        subtitleIncludeAutoGenerated: Bool = false,
        ffmpegPath: String = "",
        // Remote access
        remoteAccessEnabled: Bool = false,
        remotePort: Int = 8899,
        remoteToken: String = "",
        remoteAllowLAN: Bool = false,
        remoteRequireAuth: Bool = true,
        remoteUsername: String = "admin",
        remotePasswordHash: String = "",
        remoteReadOnly: Bool = false,
        remoteSessionMinutes: Int = 120,
        remoteTheme: String = "frost-dark",
        // RSS
        rssFeeds: [RSSFeed] = [],
        rssPollIntervalMinutes: Int = 30,
        // Backup retention
        backupKeepCount: Int = 20,
        // Updates
        autoCheckUpdates: Bool = false,
        updateFeedURL: String = ""
    ) {
        self.profiles = profiles
        self.selectedProfileName = selectedProfileName
        self.speedLimitEnabled = speedLimitEnabled
        self.defaultSaveDirectory = defaultSaveDirectory
        self.theme = theme
        self.language = language
        self.launchAtLogin = launchAtLogin
        self.launchMinimized = launchMinimized
        self.menuBarExtraEnabled = menuBarExtraEnabled
        self.defaultFolderRule = defaultFolderRule
        self.existingFileReaction = existingFileReaction
        self.clipboardMonitorEnabled = clipboardMonitorEnabled
        self.hlsMaxHeight = hlsMaxHeight
        self.detailPanelPosition = detailPanelPosition
        self.proxyMode = proxyMode
        self.proxyType = proxyType
        self.proxyAllProtocols = proxyAllProtocols
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.connectionTimeout = connectionTimeout
        self.retryCount = retryCount
        self.retryInterval = retryInterval
        self.autoRetryEnabled = autoRetryEnabled
        self.autoRetryMaxAttempts = autoRetryMaxAttempts
        self.userAgent = userAgent
        self.cookieAuthEnabled = cookieAuthEnabled
        self.btMakeDefaultClient = btMakeDefaultClient
        self.btAutoDeleteTorrent = btAutoDeleteTorrent
        self.btWatchFolderEnabled = btWatchFolderEnabled
        self.btWatchFolderPath = btWatchFolderPath
        self.btWatchStartWithoutConfirmation = btWatchStartWithoutConfirmation
        self.btEncryptionMode = btEncryptionMode
        self.btEnableDHT = btEnableDHT
        self.btEnablePeX = btEnablePeX
        self.btEnableLPD = btEnableLPD
        self.btEnableUTP = btEnableUTP
        self.notifyOnAdded = notifyOnAdded
        self.notifyOnCompleted = notifyOnCompleted
        self.notifyOnFailed = notifyOnFailed
        self.notifyOnlyWhenInactive = notifyOnlyWhenInactive
        self.notificationSound = notificationSound
        self.preventSleepWhileDownloading = preventSleepWhileDownloading
        self.allowSleepIfResumable = allowSleepIfResumable
        self.allowSleepWhileSeeding = allowSleepWhileSeeding
        self.pauseBelowBatteryThreshold = pauseBelowBatteryThreshold
        self.batteryThresholdPercent = batteryThresholdPercent
        self.dontSeedOnBattery = dontSeedOnBattery
        self.backupEnabled = backupEnabled
        self.backupIntervalHours = backupIntervalHours
        self.antivirusEnabled = antivirusEnabled
        self.antivirusScanner = antivirusScanner
        self.antivirusExecutablePath = antivirusExecutablePath
        self.antivirusArgumentTemplate = antivirusArgumentTemplate
        self.autoShutdownAction = autoShutdownAction
        self.scheduleEnabled = scheduleEnabled
        self.scheduleStartMinute = scheduleStartMinute
        self.scheduleEndMinute = scheduleEndMinute
        self.scheduleDays = scheduleDays
        self.scheduleProfileName = scheduleProfileName
        self.pauseOnExpensiveNetwork = pauseOnExpensiveNetwork
        self.pauseOnConstrainedNetwork = pauseOnConstrainedNetwork
        self.postDownloadExtractArchives = postDownloadExtractArchives
        self.postDownloadScriptEnabled = postDownloadScriptEnabled
        self.postDownloadScriptPath = postDownloadScriptPath
        self.postDownloadScriptArgs = postDownloadScriptArgs
        self.autoRedownloadOnRemoteChange = autoRedownloadOnRemoteChange
        self.subtitleDownloadEnabled = subtitleDownloadEnabled
        self.subtitleLanguages = subtitleLanguages
        self.subtitleIncludeAutoGenerated = subtitleIncludeAutoGenerated
        self.ffmpegPath = ffmpegPath
        self.remoteAccessEnabled = remoteAccessEnabled
        self.remotePort = remotePort
        self.remoteToken = remoteToken
        self.remoteAllowLAN = remoteAllowLAN
        self.remoteRequireAuth = remoteRequireAuth
        self.remoteUsername = remoteUsername
        self.remotePasswordHash = remotePasswordHash
        self.remoteReadOnly = remoteReadOnly
        self.remoteSessionMinutes = remoteSessionMinutes
        self.remoteTheme = remoteTheme
        self.rssFeeds = rssFeeds
        self.rssPollIntervalMinutes = rssPollIntervalMinutes
        self.backupKeepCount = backupKeepCount
        self.autoCheckUpdates = autoCheckUpdates
        self.updateFeedURL = updateFeedURL
    }

    private enum CodingKeys: String, CodingKey {
        case profiles, selectedProfileName, speedLimitEnabled, defaultSaveDirectory
        case theme, language, launchAtLogin, launchMinimized, menuBarExtraEnabled, defaultFolderRule
        case existingFileReaction, clipboardMonitorEnabled, hlsMaxHeight, detailPanelPosition
        case proxyMode, proxyType, proxyAllProtocols, proxyHost, proxyPort, connectionTimeout, retryCount
        case retryInterval, autoRetryEnabled, autoRetryMaxAttempts, userAgent, cookieAuthEnabled
        case btMakeDefaultClient, btAutoDeleteTorrent, btWatchFolderEnabled
        case btWatchFolderPath, btWatchStartWithoutConfirmation, btEncryptionMode
        case btEnableDHT, btEnablePeX, btEnableLPD, btEnableUTP
        case notifyOnAdded, notifyOnCompleted, notifyOnFailed
        case notifyOnlyWhenInactive, notificationSound
        case preventSleepWhileDownloading, allowSleepIfResumable, allowSleepWhileSeeding
        case pauseBelowBatteryThreshold, batteryThresholdPercent, dontSeedOnBattery
        case backupEnabled, backupIntervalHours
        case antivirusEnabled, antivirusScanner, antivirusExecutablePath, antivirusArgumentTemplate
        case autoShutdownAction
        case scheduleEnabled, scheduleStartMinute, scheduleEndMinute, scheduleDays, scheduleProfileName
        case pauseOnExpensiveNetwork, pauseOnConstrainedNetwork
        case postDownloadExtractArchives, postDownloadScriptEnabled
        case postDownloadScriptPath, postDownloadScriptArgs
        case autoRedownloadOnRemoteChange
        case subtitleDownloadEnabled, subtitleLanguages, subtitleIncludeAutoGenerated, ffmpegPath
        case remoteAccessEnabled, remotePort, remoteToken, remoteAllowLAN
        case remoteRequireAuth, remoteUsername, remotePasswordHash, remoteReadOnly
        case remoteSessionMinutes, remoteTheme
        case rssFeeds, rssPollIntervalMinutes
        case backupKeepCount
        case autoCheckUpdates, updateFeedURL
    }

    /// Decodes every field with `decodeIfPresent`, falling back to the default
    /// so OLD persisted blobs — written before these keys existed — still load
    /// cleanly instead of throwing on a missing key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decodeIfPresent([TrafficProfile].self, forKey: .profiles) ?? TrafficProfile.defaults
        selectedProfileName = try c.decodeIfPresent(String.self, forKey: .selectedProfileName) ?? TrafficProfile.medium.name
        speedLimitEnabled = try c.decodeIfPresent(Bool.self, forKey: .speedLimitEnabled) ?? true
        defaultSaveDirectory = try c.decodeIfPresent(String.self, forKey: .defaultSaveDirectory) ?? AppSettings.systemDownloadsDirectory
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "English"
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        launchMinimized = try c.decodeIfPresent(Bool.self, forKey: .launchMinimized) ?? false
        menuBarExtraEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuBarExtraEnabled) ?? true
        defaultFolderRule = try c.decodeIfPresent(String.self, forKey: .defaultFolderRule) ?? "fixed"
        existingFileReaction = try c.decodeIfPresent(String.self, forKey: .existingFileReaction) ?? "rename"
        clipboardMonitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardMonitorEnabled) ?? false
        hlsMaxHeight = try c.decodeIfPresent(Int.self, forKey: .hlsMaxHeight) ?? 0
        detailPanelPosition = try c.decodeIfPresent(String.self, forKey: .detailPanelPosition) ?? "right"
        proxyMode = try c.decodeIfPresent(String.self, forKey: .proxyMode) ?? "none"
        proxyType = try c.decodeIfPresent(String.self, forKey: .proxyType) ?? "http"
        proxyAllProtocols = try c.decodeIfPresent(Bool.self, forKey: .proxyAllProtocols) ?? false
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? ""
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 0
        connectionTimeout = try c.decodeIfPresent(Double.self, forKey: .connectionTimeout) ?? 30
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 3
        retryInterval = try c.decodeIfPresent(Double.self, forKey: .retryInterval) ?? 5
        autoRetryEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoRetryEnabled) ?? false
        autoRetryMaxAttempts = try c.decodeIfPresent(Int.self, forKey: .autoRetryMaxAttempts) ?? 5
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? "GoelDownloader/1.0 (macOS)"
        cookieAuthEnabled = try c.decodeIfPresent(Bool.self, forKey: .cookieAuthEnabled) ?? true
        btMakeDefaultClient = try c.decodeIfPresent(Bool.self, forKey: .btMakeDefaultClient) ?? false
        btAutoDeleteTorrent = try c.decodeIfPresent(Bool.self, forKey: .btAutoDeleteTorrent) ?? false
        btWatchFolderEnabled = try c.decodeIfPresent(Bool.self, forKey: .btWatchFolderEnabled) ?? false
        btWatchFolderPath = try c.decodeIfPresent(String.self, forKey: .btWatchFolderPath) ?? ""
        btWatchStartWithoutConfirmation = try c.decodeIfPresent(Bool.self, forKey: .btWatchStartWithoutConfirmation) ?? false
        btEncryptionMode = try c.decodeIfPresent(String.self, forKey: .btEncryptionMode) ?? "prefer"
        btEnableDHT = try c.decodeIfPresent(Bool.self, forKey: .btEnableDHT) ?? true
        btEnablePeX = try c.decodeIfPresent(Bool.self, forKey: .btEnablePeX) ?? true
        btEnableLPD = try c.decodeIfPresent(Bool.self, forKey: .btEnableLPD) ?? true
        btEnableUTP = try c.decodeIfPresent(Bool.self, forKey: .btEnableUTP) ?? true
        notifyOnAdded = try c.decodeIfPresent(Bool.self, forKey: .notifyOnAdded) ?? false
        notifyOnCompleted = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCompleted) ?? true
        notifyOnFailed = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFailed) ?? true
        notifyOnlyWhenInactive = try c.decodeIfPresent(Bool.self, forKey: .notifyOnlyWhenInactive) ?? false
        notificationSound = try c.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? true
        preventSleepWhileDownloading = try c.decodeIfPresent(Bool.self, forKey: .preventSleepWhileDownloading) ?? true
        allowSleepIfResumable = try c.decodeIfPresent(Bool.self, forKey: .allowSleepIfResumable) ?? false
        allowSleepWhileSeeding = try c.decodeIfPresent(Bool.self, forKey: .allowSleepWhileSeeding) ?? false
        pauseBelowBatteryThreshold = try c.decodeIfPresent(Bool.self, forKey: .pauseBelowBatteryThreshold) ?? false
        batteryThresholdPercent = try c.decodeIfPresent(Int.self, forKey: .batteryThresholdPercent) ?? 20
        dontSeedOnBattery = try c.decodeIfPresent(Bool.self, forKey: .dontSeedOnBattery) ?? false
        backupEnabled = try c.decodeIfPresent(Bool.self, forKey: .backupEnabled) ?? false
        backupIntervalHours = try c.decodeIfPresent(Int.self, forKey: .backupIntervalHours) ?? 24
        antivirusEnabled = try c.decodeIfPresent(Bool.self, forKey: .antivirusEnabled) ?? false
        antivirusScanner = try c.decodeIfPresent(String.self, forKey: .antivirusScanner) ?? ""
        antivirusExecutablePath = try c.decodeIfPresent(String.self, forKey: .antivirusExecutablePath) ?? ""
        antivirusArgumentTemplate = try c.decodeIfPresent(String.self, forKey: .antivirusArgumentTemplate) ?? "%path%"
        autoShutdownAction = try c.decodeIfPresent(String.self, forKey: .autoShutdownAction) ?? "none"
        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? false
        scheduleStartMinute = try c.decodeIfPresent(Int.self, forKey: .scheduleStartMinute) ?? 22 * 60
        scheduleEndMinute = try c.decodeIfPresent(Int.self, forKey: .scheduleEndMinute) ?? 7 * 60
        scheduleDays = try c.decodeIfPresent([Int].self, forKey: .scheduleDays) ?? [1, 2, 3, 4, 5, 6, 7]
        scheduleProfileName = try c.decodeIfPresent(String.self, forKey: .scheduleProfileName) ?? ""
        pauseOnExpensiveNetwork = try c.decodeIfPresent(Bool.self, forKey: .pauseOnExpensiveNetwork) ?? false
        pauseOnConstrainedNetwork = try c.decodeIfPresent(Bool.self, forKey: .pauseOnConstrainedNetwork) ?? false
        postDownloadExtractArchives = try c.decodeIfPresent(Bool.self, forKey: .postDownloadExtractArchives) ?? false
        postDownloadScriptEnabled = try c.decodeIfPresent(Bool.self, forKey: .postDownloadScriptEnabled) ?? false
        postDownloadScriptPath = try c.decodeIfPresent(String.self, forKey: .postDownloadScriptPath) ?? ""
        postDownloadScriptArgs = try c.decodeIfPresent(String.self, forKey: .postDownloadScriptArgs) ?? "%path%"
        autoRedownloadOnRemoteChange = try c.decodeIfPresent(Bool.self, forKey: .autoRedownloadOnRemoteChange) ?? false
        subtitleDownloadEnabled = try c.decodeIfPresent(Bool.self, forKey: .subtitleDownloadEnabled) ?? false
        subtitleLanguages = try c.decodeIfPresent(String.self, forKey: .subtitleLanguages) ?? "en"
        subtitleIncludeAutoGenerated = try c.decodeIfPresent(Bool.self, forKey: .subtitleIncludeAutoGenerated) ?? false
        ffmpegPath = try c.decodeIfPresent(String.self, forKey: .ffmpegPath) ?? ""
        remoteAccessEnabled = try c.decodeIfPresent(Bool.self, forKey: .remoteAccessEnabled) ?? false
        remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort) ?? 8899
        remoteToken = try c.decodeIfPresent(String.self, forKey: .remoteToken) ?? ""
        remoteAllowLAN = try c.decodeIfPresent(Bool.self, forKey: .remoteAllowLAN) ?? false
        remoteRequireAuth = try c.decodeIfPresent(Bool.self, forKey: .remoteRequireAuth) ?? true
        remoteUsername = try c.decodeIfPresent(String.self, forKey: .remoteUsername) ?? "admin"
        remotePasswordHash = try c.decodeIfPresent(String.self, forKey: .remotePasswordHash) ?? ""
        remoteReadOnly = try c.decodeIfPresent(Bool.self, forKey: .remoteReadOnly) ?? false
        remoteSessionMinutes = try c.decodeIfPresent(Int.self, forKey: .remoteSessionMinutes) ?? 120
        remoteTheme = try c.decodeIfPresent(String.self, forKey: .remoteTheme) ?? "frost-dark"
        rssFeeds = try c.decodeIfPresent([RSSFeed].self, forKey: .rssFeeds) ?? []
        rssPollIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .rssPollIntervalMinutes) ?? 30
        backupKeepCount = try c.decodeIfPresent(Int.self, forKey: .backupKeepCount) ?? 20
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? false
        updateFeedURL = try c.decodeIfPresent(String.self, forKey: .updateFeedURL) ?? ""
    }

    /// The currently selected profile, falling back to the first available (or
    /// `.medium`) if the stored name no longer resolves.
    public var selectedProfile: TrafficProfile {
        profiles.first { $0.name == selectedProfileName }
            ?? profiles.first
            ?? .medium
    }

    /// The profile actually applied to the engines. Identical to
    /// ``selectedProfile`` except that, when ``speedLimitEnabled`` is `false`,
    /// the download/upload byte caps are forced to `0` (unlimited). The
    /// simultaneous-download, connection and metadata caps are never touched by
    /// the snail — those are queue policy, not bandwidth.
    public var effectiveProfile: TrafficProfile {
        guard !speedLimitEnabled else { return selectedProfile }
        var profile = selectedProfile
        profile.maxDownloadBytesPerSec = 0
        profile.maxUploadBytesPerSec = 0
        return profile
    }

    /// The user's Downloads folder, or the temporary directory if it can't be
    /// located.
    public static var systemDownloadsDirectory: String {
        FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?
            .path
            ?? NSTemporaryDirectory()
    }
}
