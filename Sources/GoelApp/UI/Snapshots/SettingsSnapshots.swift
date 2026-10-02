#if DEBUG
import SwiftUI
import GoelCore

/// The Settings area's snapshots. Owned by the Settings area agent: add entries here only, named
/// `settings.<screen>`, e.g. `StudioSnapshotEntry("settings.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only settings.`
@MainActor
enum SettingsSnapshots {
    static let windowSize = CGSize(width: 1080, height: 720)
    /// The content column of a 1080 pt window: minus the 230 pt list and its hairline.
    static let paneWidth: CGFloat = 849

    static var entries: [StudioSnapshotEntry] {
        windowEntries + paneEntries + stateEntries
    }

    private static var windowEntries: [StudioSnapshotEntry] {
        let panes: [(String, SettingsView.Pane, String)] = [
            ("general", .general, ""), ("speed", .traffic, ""), ("scheduler", .scheduler, ""),
            ("rules", .rules, ""), ("browser", .browser, ""), ("web", .remote, ""),
            ("search", .general, "sleep"), ("nomatch", .general, "qwertyuiop"),
        ]
        return panes.map { name, pane, query in
            StudioSnapshotEntry("settings.window.\(name)", width: windowSize.width, height: windowSize.height) { _ in
                SettingsView(initialPane: pane, initialSearch: query)
                    .settingsSnapshotEnvironment(SettingsSnapshotModel.rich)
            }
        }
    }

    /// Every pane at full length, with the rich sample settings.
    private static var paneEntries: [StudioSnapshotEntry] {
        SettingsView.Pane.allCases.map { pane in
            StudioSnapshotEntry("settings.pane.\(slug(pane))", width: paneWidth) { _ in
                SettingsPaneContent(pane: pane)
                    .settingsSnapshotPage(SettingsSnapshotModel.rich)
            }
        }
    }

    private static var stateEntries: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("settings.state.defaults-general", width: paneWidth) { _ in
                SettingsPaneContent(pane: .general).settingsSnapshotPage(SettingsSnapshotModel.plain)
            },
            StudioSnapshotEntry("settings.state.rules-empty", width: paneWidth) { _ in
                SettingsPaneContent(pane: .rules).settingsSnapshotPage(SettingsSnapshotModel.plain)
            },
            StudioSnapshotEntry("settings.state.web-off", width: paneWidth) { _ in
                SettingsPaneContent(pane: .remote).settingsSnapshotPage(SettingsSnapshotModel.plain)
            },
            StudioSnapshotEntry("settings.state.web-hardening", width: paneWidth) { _ in
                SettingsPaneContent(pane: .remote)
                    .settingsSnapshotPage(SettingsSnapshotModel.rich, showsHardening: true)
            },
            StudioSnapshotEntry("settings.state.multipath-off", width: paneWidth) { _ in
                SettingsPaneContent(pane: .aggregation).settingsSnapshotPage(SettingsSnapshotModel.plain)
            },
            StudioSnapshotEntry("settings.state.notifications-denied", width: paneWidth) { _ in
                SettingsPaneContent(pane: .notifications)
                    .settingsSnapshotPage(SettingsSnapshotModel.plain, permission: .denied)
            },
            StudioSnapshotEntry("settings.state.notifications-not-asked", width: paneWidth) { _ in
                SettingsPaneContent(pane: .notifications)
                    .settingsSnapshotPage(SettingsSnapshotModel.plain, permission: .notAsked)
            },
            StudioSnapshotEntry("settings.state.browser-setup", width: paneWidth) { _ in
                SettingsPaneContent(pane: .browser)
                    .settingsSnapshotPage(SettingsSnapshotModel.plain, safariEnabled: nil, setupBrowsers: true)
            },
            StudioSnapshotEntry("settings.state.licence-detail", width: paneWidth) { _ in
                LicenceSettingsPane(showsDetail: true)
                    .settingsSnapshotPage(SettingsSnapshotModel.plain)
            },
            StudioSnapshotEntry("settings.state.narrow-general", width: 560) { _ in
                SettingsPaneContent(pane: .general).settingsSnapshotPage(SettingsSnapshotModel.rich)
            },
            StudioSnapshotEntry("settings.rules.editor", width: 580) { _ in
                RuleEditorSheet(rule: SettingsSnapshotModel.sampleRules[0],
                                history: SettingsSnapshotModel.ruleHistory) { _ in }
                    .settingsSnapshotEnvironment(SettingsSnapshotModel.rich)
            },
            StudioSnapshotEntry("settings.rules.editor-new", width: 580) { _ in
                RuleEditorSheet(rule: RuleEditorSheet.blankRule(),
                                history: SettingsSnapshotModel.ruleHistory) { _ in }
                    .settingsSnapshotEnvironment(SettingsSnapshotModel.rich)
            },
        ]
    }

    private static func slug(_ pane: SettingsView.Pane) -> String {
        switch pane {
        case .general: return "general"
        case .rules: return "rules"
        case .notifications: return "notifications"
        case .network: return "network"
        case .traffic: return "speed"
        case .bittorrent: return "bittorrent"
        case .scheduler: return "scheduler"
        case .rss: return "rss"
        case .aggregation: return "multipath"
        case .afterDownload: return "extract"
        case .antivirus: return "antivirus"
        case .media: return "media"
        case .browser: return "browser"
        case .remote: return "web"
        case .backup: return "backup"
        case .audit: return "audit"
        case .diagnostics: return "diagnostics"
        case .license: return "licence"
        }
    }
}

private extension View {
    func settingsSnapshotEnvironment(_ model: AppViewModel, permission: NotificationService.Permission = .allowed,
                                     safariEnabled: Bool? = true, setupBrowsers: Bool = false,
                                     showsHardening: Bool = false) -> some View {
        environment(\.settingsPreviewFixtures, SettingsPreviewFixtures(
            permission: permission,
            browserStatuses: setupBrowsers ? SettingsSnapshotModel.setupBrowsers : SettingsSnapshotModel.browsers,
            safariEnabled: safariEnabled,
            credentials: SettingsSnapshotCredentials(),
            ruleHistory: SettingsSnapshotModel.ruleHistory,
            adapters: SettingsSnapshotModel.adapters,
            showsHardening: showsHardening))
        .studioSampleEnvironment(model)
    }

    /// A pane as the window's content column draws it.
    func settingsSnapshotPage(_ model: AppViewModel, permission: NotificationService.Permission = .allowed,
                              safariEnabled: Bool? = true, setupBrowsers: Bool = false,
                              showsHardening: Bool = false) -> some View {
        padding(.horizontal, Studio.Space.xxl)
            .padding(.top, Studio.Space.xl)
            .padding(.bottom, Studio.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Studio.Palette.canvas)
            .settingsSnapshotEnvironment(model, permission: permission, safariEnabled: safariEnabled,
                                         setupBrowsers: setupBrowsers, showsHardening: showsHardening)
    }
}

/// Sample view models for Settings: `plain` is the shared sample (factory settings); `rich` turns
/// on the optional sections so every row shows.
@MainActor
enum SettingsSnapshotModel {
    static var plain: AppViewModel { StudioSampleData.makeViewModel() }

    static var rich: AppViewModel {
        if let cachedRich { return cachedRich }
        let model = makeModel(settings: richSettings)
        cachedRich = model
        return model
    }

    private static var cachedRich: AppViewModel?

    private static func makeModel(settings: AppSettings) -> AppViewModel {
        let store = try? PersistenceStore()
        let manager = DownloadManager(
            httpEngine: SnapshotEngine(kind: .http),
            torrentEngine: SnapshotEngine(kind: .torrent),
            hlsEngine: SnapshotEngine(kind: .hls),
            ftpEngine: SnapshotEngine(kind: .ftp),
            sftpEngine: SnapshotEngine(kind: .sftp),
            settings: settings,
            store: store,
            power: SnapshotPlatform(),
            folderWatch: SnapshotPlatform(),
            scanner: SnapshotPlatform(),
            credentials: SnapshotPlatform())
        let model = AppViewModel(system: SnapshotPlatform(), opened: AppViewModel.OpenedStore(store: store),
                                 manager: manager, settings: settings)
        model.installSampleSnapshot(StudioSampleData.tasks, selecting: nil)
        return model
    }

    static let sampleRules: [AutoSortRule] = [
        AutoSortRule(name: "Linux ISOs", conditions: [
            .init(field: .domain, op: .isAnyOf, value: "releases.ubuntu.com, cdimage.debian.org, getfedora.org"),
            .init(field: .fileExtension, op: .isEqual, value: "iso"),
        ], folder: StudioSampleData.downloads + "/Disc images/Linux", tag: "linux"),
        AutoSortRule(name: "Big videos wait for night", conditions: [
            .init(field: .size, op: .largerThan, value: "4 GB"),
        ], startPaused: true),
        AutoSortRule(name: "Work documents", conditions: [
            .init(field: .domain, op: .contains, value: "company.com"),
        ], folder: NSHomeDirectory() + "/Documents/Work", tag: "work", priority: .high),
        AutoSortRule(name: "Throttle archive.org", enabled: false, conditions: [
            .init(field: .domain, op: .isEqual, value: "archive.org"),
        ], speedLimitBytesPerSec: 5_000_000),
    ]

    static let ruleHistory: [AutoSortCandidate] = [
        ("ubuntu-24.04.1-desktop-amd64.iso", "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso",
         6_114_656_256),
        ("debian-12.6.0-amd64-DVD-1.iso", "https://cdimage.debian.org/debian-cd/debian-12.6.0-amd64-DVD-1.iso",
         3_994_091_520),
        ("Cosmos.Laundromat.2015.1080p.mkv", "magnet:?xt=urn:btih:cosmos", 17_000_000_000),
        ("Q3-board-pack.pdf", "https://files.company.com/q3/Q3-board-pack.pdf", 8_200_000),
        ("Figma-124.dmg", "https://desktop.figma.com/mac/Figma-124.dmg", 210_000_000),
        ("BigBuckBunny.mp4", "https://archive.org/download/BigBuckBunny.mp4", 740_000_000),
    ].map { (name: String, url: String, size: Int64) in
        AutoSortCandidate(fileName: name, url: url, host: URL(string: url)?.host?.lowercased() ?? "", size: size)
    }

    static let browsers: [BrowserStatus] = [
        BrowserStatus(name: "Chrome", helper: .installed, lastSeen: Date().addingTimeInterval(-300),
                      lastCapture: Date().addingTimeInterval(-3_600)),
        BrowserStatus(name: "Firefox", helper: .missing),
    ]

    static let setupBrowsers: [BrowserStatus] = [
        BrowserStatus(name: "Brave", helper: .installed),
        BrowserStatus(name: "Edge", helper: .stale, lastSeen: Date().addingTimeInterval(-86_400)),
    ]

    static let adapters: [NetworkAdapter] = [
        NetworkAdapter(bsdName: "en0", displayName: "Wi-Fi", type: "wifi", ipv4: "192.168.0.42", ipv6: nil,
                       isUp: true, isExpensive: false),
        NetworkAdapter(bsdName: "en7", displayName: "USB 10/100/1G LAN", type: "wired", ipv4: "192.168.1.20",
                       ipv6: nil, isUp: true, isExpensive: false),
        NetworkAdapter(bsdName: "en9", displayName: "iPhone", type: "cellular", ipv4: "172.20.10.3", ipv6: nil,
                       isUp: true, isExpensive: true),
    ]

    private static var richSettings: AppSettings {
        var settings = AppSettings()
        settings.theme = StudioAppearanceMode.system.storedValue
        settings.clipboardMonitorEnabled = true
        settings.defaultFolderRule = "byType"
        settings.pauseBelowBatteryThreshold = true
        settings.batteryThresholdPercent = 20
        settings.autoSortRules = sampleRules
        settings.proxyMode = "manual"
        settings.proxyHost = "proxy.studio.lan"
        settings.proxyPort = 3128
        settings.autoRetryEnabled = true
        settings.btWatchFolderEnabled = true
        settings.btWatchFolderPath = StudioSampleData.downloads + "/Torrents"
        settings.extraTrackersEnabled = true
        settings.extraTrackersURL = "https://ngosang.github.io/trackerslist/trackers_best.txt"
        settings.scheduleEnabled = true
        settings.scheduleStartMinute = 60
        settings.scheduleEndMinute = 420
        settings.profileScheduleEnabled = true
        settings.profileSchedule = weeklySchedule(names: settings.profiles.map(\.name))
        settings.rssFeeds = [
            RSSFeed(url: "https://feeds.example.org/linux-releases.xml", titlePattern: "amd64", startPaused: false),
            RSSFeed(url: "https://podcasts.example.com/studio.rss", titlePattern: "", startPaused: true),
        ]
        settings.aggregationEnabled = true
        settings.postDownloadScriptEnabled = true
        settings.postDownloadScriptPath = "/usr/local/bin/notify-done"
        settings.postDownloadScriptArgs = "%path%"
        settings.subtitleDownloadEnabled = true
        settings.subtitleLanguages = "en, es"
        settings.remoteAccessEnabled = true
        settings.remoteAllowLAN = true
        settings.remoteRequireAuth = true
        settings.remoteUsername = "admin"
        settings.remoteToken = "9f2c4be07a1d4c5e8b3f6a7d2e1c7f3a"
        settings.remoteTLSEnabled = true
        settings.remoteTLSIdentityPath = NSHomeDirectory() + "/.goel/portal.p12"
        settings.remoteTrustedHeaderAuthEnabled = true
        settings.remoteTrustedHeaderName = "X-Forwarded-User"
        settings.auditLogEnabled = true
        return settings
    }

    /// Low through working hours, Medium on evenings and weekends, High overnight (the mockup).
    private static func weeklySchedule(names: [String]) -> [String] {
        guard names.count >= 3 else { return [] }
        var grid = Array(repeating: "", count: ProfileSchedule.slotCount)
        for day in 0..<7 {
            let weekend = day == 0 || day == 6
            for hour in 0..<24 {
                let name: String
                if hour < 7 || hour >= 23 { name = names[2] }
                else if !weekend && hour >= 9 && hour < 18 { name = names[0] }
                else if hour >= 18 || weekend { name = names[1] }
                else { name = "" }
                grid[day * 24 + hour] = name
            }
        }
        return grid
    }
}

/// A Keychain stand-in with two saved logins; writes go nowhere.
private struct SettingsSnapshotCredentials: CredentialManaging {
    func credential(forHost host: String) -> (username: String, password: String)? { nil }
    func setCredential(username: String, password: String, host: String) -> Bool { false }
    func removeCredential(host: String) -> Bool { false }
    func allCredentials() -> [HostCredential] {
        [HostCredential(host: "files.studio-partner.com", username: "vinit"),
         HostCredential(host: "intranet.example.org", username: "builds")]
    }
    func lookupCredential(forHost host: String) -> CredentialLookup { .notFound }
    func storeCredential(username: String, password: String, host: String) -> CredentialWrite { .failed(status: 0) }
}

/// An engine that accepts every call and does nothing.
private final class SnapshotEngine: DownloadEngine {
    let kind: DownloadKind

    init(kind: DownloadKind) {
        self.kind = kind
    }

    func add(_ task: DownloadTask) async {}
    func pause(_ id: DownloadTask.ID) async {}
    func resume(_ id: DownloadTask.ID) async {}
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async {}
    func applyLimits(_ profile: TrafficProfile) async {}

    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        AsyncStream { $0.finish() }
    }
}

/// No-op platform ports for the rich sample model.
private struct SnapshotPlatform: PowerControlling, FolderWatching, FileScanning, CredentialManaging, SystemActions {
    func setPreventSleep(_ on: Bool) {}
    var isOnBattery: Bool { false }

    func start(path: String, onNewTorrent: @escaping @Sendable (URL) -> Void) async {}
    func stop() async {}

    func scan(path: String, executablePath: String, argumentTemplate: String) async -> ScanResult { .clean }

    func credential(forHost host: String) -> (username: String, password: String)? { nil }
    func setCredential(username: String, password: String, host: String) -> Bool { false }
    func removeCredential(host: String) -> Bool { false }
    func allCredentials() -> [HostCredential] { [] }
    func lookupCredential(forHost host: String) -> CredentialLookup { .notFound }
    func storeCredential(username: String, password: String, host: String) -> CredentialWrite { .failed(status: 0) }

    func post(_ notifications: [AppNotification], sound: Bool) {}
    func perform(_ intent: DrainIntent) {}
}
#endif
