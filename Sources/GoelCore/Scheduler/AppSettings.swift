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

    /// How the default save folder is chosen: `automatic` | `byType` |
    /// `bySource` | `fixed`.
    public var defaultFolderRule: String

    // MARK: Network

    /// Proxy selection: `none` | `system` | `manual`.
    public var proxyMode: String

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

    public init(
        profiles: [TrafficProfile] = TrafficProfile.defaults,
        selectedProfileName: String = TrafficProfile.medium.name,
        speedLimitEnabled: Bool = true,
        defaultSaveDirectory: String = AppSettings.systemDownloadsDirectory,
        // General
        theme: String = "system",
        language: String = "English",
        launchAtLogin: Bool = false,
        launchMinimized: Bool = false,
        defaultFolderRule: String = "fixed",
        // Network
        proxyMode: String = "none",
        proxyHost: String = "",
        proxyPort: Int = 0,
        connectionTimeout: Double = 30,
        retryCount: Int = 3,
        retryInterval: Double = 5,
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
        antivirusArgumentTemplate: String = "%path%"
    ) {
        self.profiles = profiles
        self.selectedProfileName = selectedProfileName
        self.speedLimitEnabled = speedLimitEnabled
        self.defaultSaveDirectory = defaultSaveDirectory
        self.theme = theme
        self.language = language
        self.launchAtLogin = launchAtLogin
        self.launchMinimized = launchMinimized
        self.defaultFolderRule = defaultFolderRule
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.connectionTimeout = connectionTimeout
        self.retryCount = retryCount
        self.retryInterval = retryInterval
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
    }

    private enum CodingKeys: String, CodingKey {
        case profiles, selectedProfileName, speedLimitEnabled, defaultSaveDirectory
        case theme, language, launchAtLogin, launchMinimized, defaultFolderRule
        case proxyMode, proxyHost, proxyPort, connectionTimeout, retryCount
        case retryInterval, userAgent, cookieAuthEnabled
        case btMakeDefaultClient, btAutoDeleteTorrent, btWatchFolderEnabled
        case btWatchFolderPath, btWatchStartWithoutConfirmation, btEncryptionMode
        case btEnableDHT, btEnablePeX, btEnableLPD, btEnableUTP
        case notifyOnAdded, notifyOnCompleted, notifyOnFailed
        case notifyOnlyWhenInactive, notificationSound
        case preventSleepWhileDownloading, allowSleepIfResumable, allowSleepWhileSeeding
        case pauseBelowBatteryThreshold, batteryThresholdPercent, dontSeedOnBattery
        case backupEnabled, backupIntervalHours
        case antivirusEnabled, antivirusScanner, antivirusExecutablePath, antivirusArgumentTemplate
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
        defaultFolderRule = try c.decodeIfPresent(String.self, forKey: .defaultFolderRule) ?? "fixed"
        proxyMode = try c.decodeIfPresent(String.self, forKey: .proxyMode) ?? "none"
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? ""
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 0
        connectionTimeout = try c.decodeIfPresent(Double.self, forKey: .connectionTimeout) ?? 30
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 3
        retryInterval = try c.decodeIfPresent(Double.self, forKey: .retryInterval) ?? 5
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
