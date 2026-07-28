import Foundation
import SwiftUI
import AppKit
import Network
import GoelCore

enum SidebarFilter: Hashable {
    case all
    case active
    case paused
    case completed
    case seeding
    case type(FileType)
}

struct SFTPBrowserNavigationRequest: Equatable {
    let id: UUID
    let connectionID: SFTPConnection.ID
    let path: String

    init(id: UUID = UUID(), connectionID: SFTPConnection.ID, path: String) {
        self.id = id
        self.connectionID = connectionID
        self.path = path
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case index = "#"
    case name = "Name"
    case size = "Size"
    case status = "Status"
    case added = "Added"
    case downloadSpeed = "Download speed"
    case uploadSpeed = "Upload speed"
    var id: String { rawValue }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case general = "General"
    case details = "Details"
    case progress = "Progress"
    case files = "Files"
    case connections = "Connections"
    var id: String { rawValue }
}

@MainActor
final class AppViewModel: ObservableObject {

    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var settings = AppSettings() {
        didSet {
            let selected = AppTheme(settingsValue: settings.theme)
            if ThemePalette.current != selected {
                ThemePalette.current = selected
            }
        }
    }

    /// Memoized on purpose — as a computed property this re-sorts on every SwiftUI `body` pass.
    @Published private(set) var visibleTasks: [DownloadTask] = []

    @Published var persistenceWarning: String?

    @Published private(set) var networkAdapters: [NetworkAdapter] = []

    @Published private(set) var aggregationInactiveReason: AggregationPolicy.SinglePathReason?

    var usableAggregationAdapters: [NetworkAdapter] {
        let selected = AggregationPolicy.effectiveSelection(
            selectedIds: settings.aggregationAdapterIds, all: networkAdapters)
        return AggregationPolicy.usableAdapters(
            all: networkAdapters,
            selectedIds: selected,
            includeExpensive: settings.aggregationIncludeExpensive,
            includeVPN: settings.aggregationAllowOutsideVPN
        )
    }

    @Published var selection: Set<DownloadTask.ID> = []

    @Published var primarySelection: DownloadTask.ID?

    @Published var filter: SidebarFilter = .all { didSet { recomputeVisible() } }
    @Published var search: String = "" { didSet { recomputeVisible() } }
    @Published var sortKey: SortKey = .status { didSet { recomputeVisible() } }
    @Published var sortAscending: Bool = true { didSet { recomputeVisible() } }
    @Published var detailPanelVisible: Bool = true
    @Published var detailTab: DetailTab = .general
    @Published var isAddSheetPresented: Bool = false
    @Published var isStatsPresented: Bool = false
    @Published var isHistoryPresented: Bool = false
    @Published var isLinkGrabberPresented: Bool = false

    @Published var playerItem: PlayerItem?

    struct PlayerItem: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
    }

    @Published var servers: [SFTPConnection] = []

    @Published var selectedServer: SFTPConnection.ID?

    @Published var sftpBrowserNavigation: SFTPBrowserNavigationRequest?

    @Published var editingServer: SFTPConnection?
    @Published var isServerEditorPresented: Bool = false

    @Published var serverMeta: [SFTPConnection.ID: ServerMeta] = [:]

    var osProbesInFlight: Set<SFTPConnection.ID> = []

    @Published var serverTestsInFlight: Set<SFTPConnection.ID> = []

    @Published var hostKeyReadsInFlight: Set<SFTPConnection.ID> = []

    /// The browser's `.id()` folds this in; without it "Reconnect" is a no-op.
    @Published private(set) var browserGeneration: Int = 0

    func bumpBrowserGeneration() { browserGeneration &+= 1 }

    @Published var sftpTransfers: [SFTPTransfer] = []

    @Published var sftpClipboard: SFTPClipboard?

    var sftpRemoteCopyPlans: [UUID: RemoteCopyPlan] = [:]

    @Published var sftpUploadConflicts: SFTPUploadConflictRequest?

    @Published var sftpMutationTick: Int = 0

    var sftpTransferTasks: [UUID: (task: Task<Void, Never>, cancel: CancelFlag)] = [:]

    /// Per-file, not a running total: concurrent uploads complete out of order.
    var sftpFolderBytes: [UUID: [Int: Int64]] = [:]

    struct SpeedSample: Equatable {
        var down: Double
        var up: Double
    }

    @Published private(set) var globalSpeedHistory: [SpeedSample] = []

    /// Menu bar and status bar read this, not the live sums, or the labels flicker.
    @Published private(set) var displayedCombinedSpeed = SpeedSample(down: 0, up: 0)

    private(set) var taskSpeedHistory: [DownloadTask.ID: [SpeedSample]] = [:]

    @Published private(set) var displayedTaskSpeed: [DownloadTask.ID: SpeedSample] = [:]

    func displaySpeed(for task: DownloadTask) -> SpeedSample {
        displayedTaskSpeed[task.id] ?? SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed)
    }

    private static let speedHistoryCap = 120
    /// Labels refresh at this rate; history rings take every other tick to hold their time span.
    private static let speedRefreshNanos: UInt64 = 500_000_000
    private static let speedPersistEveryTicks = 20
    private var speedSampleTick = 0
    private var speedSampler: Task<Void, Never>?
    private var lastPersistedSpeedHistory: [String: [SpeedHistoryPoint]] = [:]

    var theme: AppTheme {
        get { AppTheme(settingsValue: settings.theme) }
        set { update { $0.theme = newValue.settingsValue } }
    }

    /// Deliberately independent of ``theme``: setting it must never touch ``ThemePalette/current``.
    var remoteTheme: AppTheme {
        get { AppTheme(settingsValue: settings.remoteTheme) }
        set { update { $0.remoteTheme = newValue.settingsValue } }
    }

    /// Plaintext is salted-hashed, never persisted; "" clears the password.
    func setRemotePassword(_ plain: String) {
        let hash = RemotePassword.hash(plain)
        update { $0.remotePasswordHash = hash }
    }

    var hasRemotePassword: Bool { !settings.remotePasswordHash.isEmpty }

    var detailPanelPosition: DetailPanelPosition {
        get { DetailPanelPosition(settingsValue: settings.detailPanelPosition) }
        set { update { $0.detailPanelPosition = newValue.settingsValue } }
    }

    func toggleDetailPanelPosition() {
        detailPanelPosition = detailPanelPosition == .right ? .bottom : .right
    }

    @Published var toast: String?

    @Published var confirmRequest: ConfirmRequest?

    struct ConfirmRequest: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var confirmTitle: String
        var isDestructive: Bool
        var onConfirm: () -> Void
    }

    func requestConfirm(title: String, message: String, confirmTitle: String,
                        destructive: Bool = false, onConfirm: @escaping () -> Void) {
        confirmRequest = ConfirmRequest(title: title, message: message,
                                        confirmTitle: confirmTitle,
                                        isDestructive: destructive, onConfirm: onConfirm)
    }

    /// The Settings scene does not render the main window's overlays, so it needs its own channel.
    @Published var settingsAlert: SettingsAlert?

    struct SettingsAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var confirmTitle: String?
        var isDestructive = false
        var onConfirm: (() -> Void)?
    }

    func settingsMessage(_ title: String, _ message: String) {
        settingsAlert = SettingsAlert(title: title, message: message)
    }

    func settingsConfirm(title: String, message: String, confirmTitle: String,
                         destructive: Bool = false, onConfirm: @escaping () -> Void) {
        settingsAlert = SettingsAlert(title: title, message: message,
                                      confirmTitle: confirmTitle,
                                      isDestructive: destructive, onConfirm: onConfirm)
    }

    @Published var clipboardSuggestion: String?

    private let manager: DownloadManager
    private var updatesTask: Task<Void, Never>?

    /// Not derived from the queue — idle is not absent. `updatesTask` is set last in `start()`.
    var runningEngineKinds: Set<DownloadKind> {
        updatesTask == nil ? [] : Set(DownloadKind.allCases)
    }

    private var clipboardMonitor: ClipboardMonitor?

    private var pathMonitor: NWPathMonitor?

    private var aggregationLiveTask: Task<Void, Never>?
    private var aggregationWatchCount = 0
    private var lastVPNActive = false
    private var networkChangeObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?
    private var appTerminateObserver: NSObjectProtocol?

    private let remoteAccess = RemoteAccess()

    @Published private(set) var remotePortalFailure: String?

    private var lastClipboardHandled: String?

    private var hasAutoSelected = false

    /// Stops an earlier toast's timer clearing a later toast with identical text.
    private var toastGeneration = 0

    private var reducerState = ReducerState()

    private let fileProgress = FileProgressPublisher()

    private let dockProgress = DockProgressService()

    private let system: SystemActions

    /// Weak: scripting must never keep a discarded view model alive.
    static private(set) weak var shared: AppViewModel?

    init(system: SystemActions = LiveSystemActions()) {
        let (store, warning) = Self.makeStore()
        self.manager = DownloadManager(store: store)
        self.persistenceWarning = warning
        self.servers = SFTPConnectionStore.shared.load()
        self.system = system
        Self.shared = self
    }

    private static func makeStore() -> (PersistenceStore?, String?) {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return (try? PersistenceStore(), "Using temporary storage — downloads won’t survive relaunch.")
        }
        let appDir = dir.appendingPathComponent("GoelDownloader", isDirectory: true)
        do {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            let store = try PersistenceStore(path: appDir.appendingPathComponent("queue.sqlite").path)
            return (store, nil)
        } catch {
            return (try? PersistenceStore(), "Couldn’t open the database — downloads won’t survive relaunch.")
        }
    }

    func start() async {
        guard updatesTask == nil else { return }
        await manager.restore()
        settings = await manager.currentSettings
        ActiveWorkGate.shared.menuBarVisible = settings.menuBarExtraEnabled
        syncMediaJobCenter()
        loadPersistedSpeedHistory(await manager.loadSpeedHistory())
        let monitor = ClipboardMonitor(isEnabled: settings.clipboardMonitorEnabled) { [weak self] text in
            self?.handleClipboardChange(text)
        }
        monitor.start()
        clipboardMonitor = monitor
        let netMonitor = NWPathMonitor()
        let core = self.manager
        netMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let vpnActive = AdapterDirectory.hasActiveVPNInterface()
            // Bound out here, not `self?.` inside the Task: the policy calls must run after the VM dies.
            let model = self
            Task {
                await core.applyNetworkPolicy(expensive: expensive, constrained: constrained)
                await core.setVPNDefaultRouteActive(vpnActive)
                if let model {
                    await MainActor.run { model.refreshAggregationState() }
                }
            }
        }
        netMonitor.start(queue: DispatchQueue(label: "goel.network-path"))
        pathMonitor = netMonitor
        networkChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.system.config.network_change"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAggregationState()
        }
        await refreshAggregationState()
        startSpeedSampler()
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let manager = self.manager
            Task { await manager.reconcileCompletedFiles() }
            // A launch-only policy read would be dodged by never quitting the app.
            self.refreshManagedPolicy()
        }
        appTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.persistSpeedHistory()
        }
        applyRemoteAccess()
        SparkleUpdaterService.shared.startIfConfigured()
        if !SparkleUpdaterService.shared.isConfigured, settings.autoCheckUpdates {
            let feed = settings.updateFeedURL
            let proxy = Self.proxySpec(from: settings)
            let agent = Self.updateUserAgent(from: settings)
            Task { [weak self] in
                guard let self else { return }
                if case let .available(version, url) = await UpdateChecker.check(
                    feedURL: feed, proxy: proxy, userAgent: agent) {
                    self.offerUpdate(version: version, url: url)
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: ExternalAdd.notification, object: nil, queue: .main
        ) { [weak self] note in
            guard let box = note.object as? ExternalAdd.PayloadBox else { return }
            Task { @MainActor [weak self] in
                self?.handleExternalAdd(box.payload)
            }
        }
        ExternalAdd.drainPending { handleExternalAdd($0) }
        drainBrowserSpool()
        if settings.notifyOnAdded || settings.notifyOnCompleted || settings.notifyOnFailed {
            NotificationService.requestAuthorization()
        }
        if let warning = await manager.currentPersistenceWarning { persistenceWarning = warning }
        let stream = await manager.updates()
        let manager = self.manager
        updatesTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                let warning = await manager.currentPersistenceWarning
                await MainActor.run {
                    if self.tasks != snapshot {
                        self.tasks = snapshot
                        self.recomputeVisible()
                    }
                    // Exactly once at launch, so "Select none" sticks instead of snapping back.
                    if self.primarySelection == nil && !self.hasAutoSelected {
                        if let first = self.visibleTasks.first?.id {
                            self.hasAutoSelected = true
                            self.primarySelection = first
                            self.selection = [first]
                        }
                    }
                    self.pump(snapshot)
                    self.fileProgress.update(with: snapshot) { [weak self] id in
                        self?.pause(id)
                    }
                    self.refreshDockProgress()
                    if let warning { self.persistenceWarning = warning }
                }
            }
        }
    }

    private func recomputeVisible() {
        visibleTasks = ListPresentation.visible(
            tasks: tasks,
            filter: filter,
            search: search,
            sortKey: sortKey,
            ascending: sortAscending
        )
    }

    func count(for filter: SidebarFilter) -> Int {
        ListPresentation.count(tasks: tasks, filter: filter)
    }

    var selectedTask: DownloadTask? {
        guard let primarySelection else { return nil }
        return tasks.first { $0.id == primarySelection }
    }

    var totalDownloadSpeed: Double { tasks.reduce(0) { $0 + $1.downloadSpeed } }
    var totalUploadSpeed: Double { tasks.reduce(0) { $0 + $1.uploadSpeed } }

    var sftpUploadSpeed: Double {
        sftpTransfers.reduce(0) { $0 + ($1.isActive && $1.direction == .upload ? $1.speed : 0) }
    }
    var sftpDownloadSpeed: Double {
        sftpTransfers.reduce(0) { $0 + ($1.isActive && $1.direction == .download ? $1.speed : 0) }
    }

    var combinedDownloadSpeed: Double { totalDownloadSpeed + sftpDownloadSpeed }
    var combinedUploadSpeed: Double { totalUploadSpeed + sftpUploadSpeed }

    var preferredColorScheme: ColorScheme? { theme.colorScheme }

    func add(rawLines: String, saveDirectory: String?, priority: FilePriority,
             expectedChecksum: Checksum? = nil) {
        var sources = Self.expandedLines(rawLines).compactMap(Self.parseSource)
        let metalinks = sources.filter(Self.isMetalink)
        sources.removeAll(where: Self.isMetalink)
        for case .url(let metalink) in metalinks {
            importMetalink(metalink, saveDirectory: saveDirectory, priority: priority)
        }
        guard !sources.isEmpty else {
            if metalinks.isEmpty { toastNow("Enter a URL or magnet link first") }
            return
        }
        let existingKeys = Set(tasks.map(\.source.dedupKey))
        var batchKeys = Set<String>()
        let fresh = sources.filter {
            batchKeys.insert($0.dedupKey).inserted && !existingKeys.contains($0.dedupKey)
        }
        let skipped = sources.count - fresh.count
        guard !fresh.isEmpty else {
            toastNow(sources.count == 1 ? "Already in your list"
                                        : "All \(sources.count) are already in your list")
            return
        }
        // Never apply one checksum to every download in a batch.
        let checksum = fresh.count == 1 ? expectedChecksum : nil
        Task {
            for source in fresh {
                await manager.add(source: source, saveDirectory: saveDirectory,
                                  priority: priority, expectedChecksum: checksum)
            }
        }
        if skipped > 0 {
            toastNow("Added \(fresh.count) · skipped \(skipped) already in your list")
        } else {
            toastNow(fresh.count > 1 ? "Added \(fresh.count) downloads to queue" : "Added to queue")
        }
        filter = .all
    }

    /// Batch shorthand expansion is capped, or a hostile range floods the queue.
    static func expandedLines(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { BatchExpander.expand($0) }
    }

    func existingDuplicate(of source: DownloadSource) -> DownloadTask? {
        tasks.first { $0.source.dedupKey == source.dedupKey }
    }

    static func isMetalink(_ source: DownloadSource) -> Bool {
        guard case .url(let url) = source else { return false }
        return ["metalink", "meta4"].contains(url.pathExtension.lowercased())
    }

    private func importMetalink(_ url: URL, saveDirectory: String?, priority: FilePriority) {
        Task { @MainActor in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count <= 5_000_000 else { throw URLError(.badServerResponse) }
                let files = MetalinkParser.parse(data)
                guard !files.isEmpty else {
                    toastNow("No downloads found in the metalink")
                    return
                }
                var added = 0
                for file in files.prefix(50) {
                    guard let primary = file.urls.first,
                          let source = Self.parseSource(primary),
                          existingDuplicate(of: source) == nil else { continue }
                    await manager.add(source: source,
                                      saveDirectory: saveDirectory,
                                      priority: priority,
                                      expectedChecksum: file.checksum,
                                      mirrors: Array(file.urls.dropFirst()),
                                      suggestedName: file.name.isEmpty ? nil : file.name)
                    added += 1
                }
                toastNow(added > 0 ? "Added \(added) from metalink"
                                   : "Metalink contents already in your list")
                filter = .all
            } catch {
                toastNow("Couldn’t load the metalink file")
            }
        }
    }

    func parsedSources(in rawLines: String) -> [DownloadSource] {
        InboundAdd.parseSources(from: rawLines)
    }

    func resolveMetadata(for line: String, saveDirectory: String?) async -> DownloadPreview? {
        guard let source = Self.parseSource(line) else { return nil }
        return await manager.resolveMetadata(for: source, saveDirectory: saveDirectory)
    }

    func confirm(_ preview: DownloadPreview, saveDirectory: String?,
                 priority: FilePriority, checksum: Checksum?, startAt: Date? = nil,
                 mirrors: [String]? = nil, deselectedFileIDs: [Int]? = nil,
                 cookieHeader: String? = nil, cookieSource: CookieSource? = nil,
                 cookieHost: String? = nil) {
        guard existingDuplicate(of: preview.source) == nil else {
            toastNow("Already in your list")
            filter = .all
            return
        }
        let checksum = preview.kind == .torrent ? nil : checksum
        let source = preview.source
        let mirrors = preview.kind == .http ? mirrors : nil
        let skipFiles = preview.kind == .torrent ? deselectedFileIDs : nil
        // Torrents seed only the name: size/files must come from libtorrent's own handle.
        let seededBytes = preview.kind == .torrent ? nil : preview.totalBytes
        let seededFiles = preview.kind == .torrent ? [] : preview.files
        Task {
            await manager.add(source: source, saveDirectory: saveDirectory,
                              priority: priority, expectedChecksum: checksum,
                              scheduledAt: startAt, mirrors: mirrors,
                              suggestedName: preview.suggestedName,
                              totalBytes: seededBytes, files: seededFiles,
                              deselectedFileIDs: skipFiles,
                              cookieHeader: cookieHeader,
                              cookieSource: cookieSource,
                              cookieHost: cookieHost)
        }
        if let startAt {
            let formatter = RelativeDateTimeFormatter()
            toastNow("Will start \(formatter.localizedString(for: startAt, relativeTo: Date()))")
        } else {
            toastNow("Added to queue")
        }
        filter = .all
    }

    func handleClipboardChange(_ text: String) {
        // The clipboard is never auto-queued — it only ever raises a suggestion.
        let disposition = InboundAdd.classify(
            origin: .clipboard,
            payload: .init(lines: text)
        )
        guard case .needsConfirmation(let payload) = disposition,
              let raw = payload.lines else { return }
        let link = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { Self.parseSource($0)?.looksLikeDownloadableFile == true }
        guard let link, link != lastClipboardHandled, let source = Self.parseSource(link) else { return }
        if tasks.contains(where: { $0.source.dedupKey == source.dedupKey }) { return }
        lastClipboardHandled = link
        clipboardSuggestion = link
    }

    func acceptClipboardSuggestion() {
        guard let link = clipboardSuggestion else { return }
        clipboardSuggestion = nil
        add(rawLines: link, saveDirectory: nil, priority: .normal)
    }

    func dismissClipboardSuggestion() {
        clipboardSuggestion = nil
    }

    /// Web-triggerable `goeldownloader://` payloads must go through confirmation, never straight to the queue.
    private func handleExternalAdd(_ payload: ExternalAdd.Payload) {
        NSApp.activate(ignoringOtherApps: true)
        if payload.drainBrowserSpool {
            drainBrowserSpool()
            return
        }
        if let torrent = payload.torrentFile {
            Task { await manager.add(source: .torrentFile(torrent)) }
            toastNow("Added to queue")
            return
        }
        guard let lines = payload.lines else { return }
        if payload.needsConfirmation {
            if let first = parsedSources(in: lines).first {
                clipboardSuggestion = first.locator
            }
        } else {
            add(rawLines: lines, saveDirectory: nil, priority: .normal)
        }
    }

    /// No confirmation: only local processes can write the spool, and the host already validated it.
    private func drainBrowserSpool() {
        // Re-validate the scheme: auto-add must never open an authenticated sftp:/ftp: connection.
        let captures = BrowserSpool.drainCaptures().filter {
            DownloadSource.parse($0.locator)?.isBrowserCaptureSafe == true
        }
        guard !captures.isEmpty else { return }
        // One add per capture: batching would flatten distinct cookie scopes into one and leak them.
        for capture in captures {
            guard let source = DownloadSource.parse(capture.locator) else { continue }
            Task {
                // Re-screen against RESOLVED addresses: `localtest.me` is loopback hidden behind DNS.
                if let target = source.fetchTargetURL,
                   await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(target) == false { return }
                let task = await manager.add(source: source, priority: .normal,
                                             cookieHeader: capture.cookieHeader,
                                             cookieSource: capture.cookieHeader == nil ? CookieSource.none : .browser,
                                             cookieHost: capture.cookieHost)
                if let referer = capture.referer {
                    await manager.setRequestOptions(referer: referer, headers: nil, task: task.id)
                }
            }
        }
    }

    /// The core parser enforces the scheme allowlist (http/https/magnet/.torrent only).
    static func parseSource(_ line: String) -> DownloadSource? {
        DownloadSource.parse(line)
    }

    func pause(_ id: DownloadTask.ID) { Task { await manager.pause(id) } }
    func resume(_ id: DownloadTask.ID) { Task { await manager.resume(id) } }
    func remove(_ id: DownloadTask.ID, deleteData: Bool) {
        let name = tasks.first { $0.id == id }?.name
        // Must run BEFORE the snapshot drops the task, or selection lands on the raw-first row.
        let nextPrimary = visibleNeighbor(after: id)
        Task { await manager.remove(id, deleteData: deleteData) }
        selection.remove(id)
        if primarySelection == id { primarySelection = nextPrimary }
        if deleteData {
            toastNow(name.map { "Deleted files for “\($0)”" } ?? "Removed with data")
        } else {
            toastNow("Removed from list")
        }
    }
    func retry(_ id: DownloadTask.ID) {
        // Failed tasks need this path: resume() ignores anything not paused.
        Task { await manager.retry(id) }
    }

    func pauseAll() { Task { await manager.pauseAll() }; toastNow("Paused all downloads") }
    func resumeAll() { Task { await manager.resumeAll() }; toastNow("Resumed all downloads") }

    func setProfile(_ name: String) {
        Task {
            settings = await manager.setProfile(name)
        }
    }

    func toggleSnail() {
        let newValue = !settings.speedLimitEnabled
        Task {
            settings = await manager.setSpeedLimitEnabled(newValue)
            toastNow(newValue ? "Speed limit on · \(settings.selectedProfileName)" : "Speed limit off · Unlimited")
        }
    }

    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) {
        Task { await manager.setFilePriority(priority, fileID: fileID, task: id) }
    }

    func setDefaultSaveDirectory(_ path: String) {
        Task {
            settings = await manager.setDefaultSaveDirectory(path)
        }
    }

    func refreshAggregationState() {
        let next = AdapterDirectory.enumerate()
        let vpn = AdapterDirectory.hasActiveVPNInterface()
        let reason = DownloadManager.aggregationSinglePathReason(
            settings: settings, vpnDefaultRoute: vpn, adapters: next)

        let adaptersChanged = next != networkAdapters
        let reasonChanged = reason != aggregationInactiveReason
        let vpnChanged = vpn != lastVPNActive

        if adaptersChanged {
            withAnimation(.easeInOut(duration: 0.2)) {
                networkAdapters = next
            }
        }
        if reasonChanged {
            aggregationInactiveReason = reason
        }
        lastVPNActive = vpn

        if adaptersChanged || vpnChanged {
            Task {
                await manager.setVPNDefaultRouteActive(vpn)
                await manager.reapplyEngineConfigsPublic()
            }
        }
    }

    func beginAggregationLiveUpdates() {
        aggregationWatchCount += 1
        refreshAggregationState()
        guard aggregationLiveTask == nil else { return }
        aggregationLiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000) // 0.75 s
                guard !Task.isCancelled else { break }
                self?.refreshAggregationState()
            }
        }
    }

    func endAggregationLiveUpdates() {
        aggregationWatchCount = max(0, aggregationWatchCount - 1)
        guard aggregationWatchCount == 0 else { return }
        aggregationLiveTask?.cancel()
        aggregationLiveTask = nil
    }

    /// `mutate` runs twice on purpose: on the effective settings here, on the user's row in the actor.
    func update(_ mutate: @escaping @Sendable (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        // Must clamp before the guard below, which compares the pre-clamp value.
        copy = copy.validated()
        // `@Published` fires on every assignment; a no-op write can spin scene bindings into a loop.
        guard copy != settings else { return }
        let launchChanged = copy.launchAtLogin != settings.launchAtLogin
        let notificationsNewlyWanted =
            (copy.notifyOnAdded || copy.notifyOnCompleted || copy.notifyOnFailed) &&
            !(settings.notifyOnAdded || settings.notifyOnCompleted || settings.notifyOnFailed)
        settings = copy
        clipboardMonitor?.isEnabled = copy.clipboardMonitorEnabled
        ActiveWorkGate.shared.menuBarVisible = copy.menuBarExtraEnabled
        syncMediaJobCenter()
        Task {
            settings = await manager.apply(mutate)
            refreshAggregationState()
        }
        if launchChanged { LoginItemService.setEnabled(copy.launchAtLogin) }
        if notificationsNewlyWanted { NotificationService.requestAuthorization() }
        applyRemoteAccess()
        networkAdapters = AdapterDirectory.enumerate()
        aggregationInactiveReason = DownloadManager.aggregationSinglePathReason(
            settings: settings,
            vpnDefaultRoute: AdapterDirectory.hasActiveVPNInterface(),
            adapters: networkAdapters)
    }

    func toggleAggregationAdapter(_ bsdName: String) {
        update { s in
            var ids = Set(s.aggregationAdapterIds)
            if ids.contains(bsdName) { ids.remove(bsdName) }
            else { ids.insert(bsdName) }
            s.aggregationAdapterIds = ids.sorted()
        }
    }

    private func applyRemoteAccess() {
        let settings = self.settings
        let manager = self.manager
        Task {
            await remoteAccess.apply(settings: settings, backend: manager)
            // Reporting a refused start as success leaves the pane offering a dead link.
            let failure = await remoteAccess.lastStartFailure
            remotePortalFailure = failure?.message
        }
    }

    func checkForUpdates() {
        if SparkleUpdaterService.shared.checkForUpdates() { return }
        let feed = settings.updateFeedURL
        let proxy = Self.proxySpec(from: settings)
        let agent = Self.updateUserAgent(from: settings)
        Task { [weak self] in
            guard let self else { return }
            switch await UpdateChecker.check(feedURL: feed, proxy: proxy, userAgent: agent) {
            case let .available(version, url):
                self.offerUpdate(version: version, url: url)
            case let .upToDate(current):
                self.toastNow("Up to date — version \(current)")
            case .notConfigured:
                self.toastNow("Set an update feed URL in Settings → Advanced first")
            case let .failed(message):
                self.toastNow("Update check failed: \(message)")
            }
        }
    }

    private static func proxySpec(from settings: AppSettings) -> NetworkGuard.ProxySpec {
        NetworkGuard.ProxySpec(mode: settings.proxyMode, type: settings.proxyType,
                               host: settings.proxyHost, port: settings.proxyPort)
    }

    /// An empty User-Agent is not "no preference" — several hosts refuse it.
    private static func updateUserAgent(from settings: AppSettings) -> String {
        let trimmed = settings.userAgent.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "GoelDownloader/1.0 (macOS)" : trimmed
    }

    private func offerUpdate(version: String, url: URL) {
        requestConfirm(
            title: "Version \(version) is available",
            message: "You’re running \(UpdateChecker.currentVersion). Open the release page to download the update?",
            confirmTitle: "Open Release Page"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
    }

    func openFile(_ task: DownloadTask) {
        NSWorkspace.shared.open(URL(fileURLWithPath: task.primaryFilePath))
    }

    func playInApp(_ task: DownloadTask) {
        playerItem = PlayerItem(url: URL(fileURLWithPath: task.primaryFilePath), title: task.name)
    }

    func revealInFinder(_ task: DownloadTask) {
        let url = URL(fileURLWithPath: task.savePath)
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
        toastNow("Revealed in Finder")
    }

    func copyToPasteboard(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
        toastNow("Copied to clipboard")
    }

    private func pump(_ snapshot: [DownloadTask]) {
        let env = ReducerEnv(
            notify: NotifyPrefs(onAdded: settings.notifyOnAdded,
                                onCompleted: settings.notifyOnCompleted,
                                onFailed: settings.notifyOnFailed,
                                onlyWhenInactive: settings.notifyOnlyWhenInactive),
            isAppActive: NSApp.isActive,
            autoShutdownAction: settings.autoShutdownAction)
        let output = SnapshotReducer.reduce(reducerState, snapshot, env)
        reducerState = output.state
        refreshActiveWorkGate()
        // Drain before the banners: it may terminate the app.
        if let intent = output.drainIntent {
            update { $0.autoShutdownAction = "none" }   // one-shot: never fire twice
            system.perform(intent)
        }
        system.post(output.notifications, sound: settings.notificationSound)
    }

    private func startSpeedSampler() {
        guard speedSampler == nil else { return }
        speedSampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.speedRefreshNanos)
                guard let self else { return }
                self.takeSpeedSample()
            }
        }
    }

    private func takeSpeedSample() {
        // Skip when fully idle, or the @Published writes re-render the whole app twice a second.
        let hasActive = tasks.contains { $0.status.isActive } || sftpTransfers.contains { $0.isActive }
        if !hasActive,
           globalSpeedHistory.allSatisfy({ $0 == SpeedSample(down: 0, up: 0) }),
           displayedCombinedSpeed == SpeedSample(down: 0, up: 0) {
            return
        }
        speedSampleTick &+= 1
        let recordHistory = speedSampleTick.isMultiple(of: 2)
        let nextCombined = SpeedSample(down: combinedDownloadSpeed, up: combinedUploadSpeed)
        if nextCombined != displayedCombinedSpeed { displayedCombinedSpeed = nextCombined }
        var sample = SpeedSample(down: 0, up: 0)
        var nextTaskSpeed = displayedTaskSpeed
        for task in tasks {
            sample.down += task.downloadSpeed
            sample.up += task.uploadSpeed
            nextTaskSpeed[task.id] = SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed)
            guard recordHistory, task.status.isActive else { continue }
            var history = taskSpeedHistory[task.id] ?? []
            history.append(SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed))
            if history.count > Self.speedHistoryCap { history.removeFirst() }
            taskSpeedHistory[task.id] = history
        }
        let known = Set(tasks.map(\.id))
        taskSpeedHistory = taskSpeedHistory.filter { known.contains($0.key) }
        nextTaskSpeed = nextTaskSpeed.filter { known.contains($0.key) }
        if nextTaskSpeed != displayedTaskSpeed { displayedTaskSpeed = nextTaskSpeed }
        if recordHistory {
            globalSpeedHistory.append(sample)
            if globalSpeedHistory.count > Self.speedHistoryCap { globalSpeedHistory.removeFirst() }
        }
        if speedSampleTick.isMultiple(of: Self.speedPersistEveryTicks) {
            persistSpeedHistory()
        }
    }

    private func persistSpeedHistory() {
        var out: [String: [SpeedHistoryPoint]] = [:]
        for task in tasks where !task.status.isTerminal {
            guard let samples = taskSpeedHistory[task.id], !samples.isEmpty else { continue }
            out[task.id.uuidString] = samples.map { SpeedHistoryPoint(down: $0.down, up: $0.up) }
        }
        guard out != lastPersistedSpeedHistory else { return }
        lastPersistedSpeedHistory = out
        let manager = self.manager
        Task { await manager.persistSpeedHistory(out) }
    }

    private func loadPersistedSpeedHistory(_ saved: [String: [SpeedHistoryPoint]]) {
        lastPersistedSpeedHistory = saved
        guard !saved.isEmpty else { return }
        var restored: [DownloadTask.ID: [SpeedSample]] = [:]
        for (idString, points) in saved {
            guard let id = UUID(uuidString: idString) else { continue }
            restored[id] = points.map { SpeedSample(down: $0.down, up: $0.up) }
        }
        taskSpeedHistory = restored
    }

    func fetchStats() async -> TransferStats {
        await manager.currentStats
    }

    func fetchHistory() async -> [HistoryEntry] {
        await manager.history()
    }

    func redownload(_ entry: HistoryEntry) {
        add(rawLines: entry.locator, saveDirectory: nil, priority: .normal)
    }

    func deleteHistoryEntry(_ id: UUID) {
        Task { await manager.removeHistoryEntry(id) }
        toastNow("Entry removed")
    }

    func clearHistory() {
        Task { await manager.clearHistory() }
        toastNow("History cleared")
    }

    func exportHistoryCSV(_ entries: [HistoryEntry], to url: URL) {
        let iso = ISO8601DateFormatter()
        var rows = ["name,link,size_bytes,save_path,completed_at"]
        for entry in entries {
            rows.append([
                entry.name,
                entry.locator,
                entry.totalBytes.map(String.init) ?? "",
                entry.savePath,
                iso.string(from: entry.completedAt),
            ].map(CSVEncoder.field).joined(separator: ","))
        }
        do {
            try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            toastNow("History exported")
        } catch {
            toastNow("Export failed")
        }
    }

    func setScheduledStart(_ date: Date?, task id: DownloadTask.ID) {
        Task { await manager.setScheduledStart(date, task: id) }
        if let date {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            toastNow("Will start \(formatter.localizedString(for: date, relativeTo: Date()))")
        } else {
            toastNow("Scheduled start cancelled")
        }
    }

    func exportBackup(to url: URL) {
        Task {
            do {
                let data = try await manager.exportEnvelope()
                try data.write(to: url)
                toastNow("Backup exported")
            } catch {
                toastNow("Export failed")
            }
        }
    }

    /// A backup file is untrusted input and adopting its settings cannot be undone — always confirm.
    func importBackup(from url: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            toastNow("Import failed — couldn’t read that file")
            return
        }
        guard let incoming = Self.backupSettings(in: data) else {
            toastNow("Import failed — not a valid backup file")
            return
        }
        requestConfirm(
            title: "Import this backup?",
            message: Self.importSummary(
                changes: Self.adoptableSettingChanges(from: incoming, current: settings)),
            confirmTitle: "Import"
        ) { [weak self] in
            self?.adoptBackup(data)
        }
    }

    private func adoptBackup(_ data: Data) {
        Task {
            do {
                let added = try await manager.importEnvelope(data)
                settings = await manager.currentSettings
                toastNow(added > 0 ? "Imported \(added) download\(added == 1 ? "" : "s")"
                                   : "Nothing new to import")
            } catch {
                toastNow("Import failed — not a valid backup file")
            }
        }
    }

    private struct BackupSettingsOnly: Decodable {
        let settings: AppSettings
    }

    private static func backupSettings(in data: Data) -> AppSettings? {
        (try? JSONDecoder().decode(BackupSettingsOnly.self, from: data))?.settings
    }

    /// Advisory only — this restates the actor's refusal list and must stay in step with it.
    private static func adoptableSettingChanges(from incoming: AppSettings,
                                                current: AppSettings) -> [String] {
        guard incoming != current,
              let new = jsonFields(incoming), let mine = jsonFields(current) else { return [] }
        let protectedPrefixes = ["proxy", "remote", "antivirus", "postDownloadScript", "btWatch"]
        let protectedKeys: Set<String> = [
            "ffmpegPath", "defaultSaveDirectory", "auditLogDirectory", "rssFeeds", "updateFeedURL",
        ]
        return Set(new.keys).union(mine.keys).filter { key in
            guard !protectedKeys.contains(key),
                  !protectedPrefixes.contains(where: { key.hasPrefix($0) }) else { return false }
            switch (new[key] as? NSObject, mine[key] as? NSObject) {
            case (nil, nil): return false
            case let (lhs?, rhs?): return !lhs.isEqual(rhs)
            default: return true
            }
        }.sorted()
    }

    private static func jsonFields(_ settings: AppSettings) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func importSummary(changes: [String]) -> String {
        let head: String
        switch changes.count {
        case 0:
            head = "Its settings match yours, so no setting changes."
        case 1...3:
            head = "It changes \(changes.count) setting\(changes.count == 1 ? "" : "s"): "
                + changes.joined(separator: ", ") + "."
        default:
            head = "It changes \(changes.count) settings, including "
                + changes.prefix(3).joined(separator: ", ") + "."
        }
        return head + " Downloads it contains are added paused; ones already in your list are skipped.\n\n"
            + "Security-sensitive settings are never taken from a backup: your proxy, the remote "
            + "portal’s access, credentials and trusted-header (SSO) sign-in, your save and watch "
            + "folders, RSS feeds, update feed, and any script or antivirus paths all stay as they are."
    }

    func setSequential(_ sequential: Bool, task id: DownloadTask.ID) {
        Task { await manager.setSequential(sequential, task: id) }
        toastNow(sequential ? "Sequential download on" : "Sequential download off")
    }

    func setTaskSpeedLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) {
        Task { await manager.setTaskSpeedLimit(bytesPerSec, task: id) }
        if let bytesPerSec, bytesPerSec > 0 {
            toastNow("Limited to \(Double(bytesPerSec).speedString) — applies on next start")
        } else {
            toastNow("Per-download limit removed")
        }
    }

    func setTaskUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) {
        Task { await manager.setTaskUploadLimit(bytesPerSec, task: id) }
        if let bytesPerSec, bytesPerSec > 0 {
            toastNow("Upload limited to \(Double(bytesPerSec).speedString)")
        } else {
            toastNow("Upload limit removed")
        }
    }

    func setSeedRatioLimit(_ ratio: Double?, task id: DownloadTask.ID) {
        Task { await manager.setSeedRatioLimit(ratio, task: id) }
        if let ratio, ratio > 0 {
            toastNow(String(format: "Will stop seeding at ratio %.1f", ratio))
        } else {
            toastNow("Seeding indefinitely")
        }
    }

    func forceRecheck(_ id: DownloadTask.ID) {
        Task { await manager.forceRecheck(id) }
        toastNow("Rechecking downloaded data…")
    }

    func forceReannounce(_ id: DownloadTask.ID) {
        Task { await manager.forceReannounce(id) }
        toastNow("Re-announcing to trackers…")
    }

    func setLabel(_ label: String?, task id: DownloadTask.ID) {
        Task { await manager.setLabel(label, task: id) }
        toastNow(label.map { "Labelled “\($0)”" } ?? "Label removed")
    }

    @MainActor
    static func promptText(title: String, message: String, confirm: String,
                           initial: String, placeholder: String? = nil,
                           width: CGFloat = 300) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        field.stringValue = initial
        if let placeholder { field.placeholderString = placeholder }
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func promptForLabel(task: DownloadTask) {
        if let value = Self.promptText(
            title: "Label for “\(task.name)”",
            message: "Group this download under a category. Leave empty to remove.",
            confirm: "Save", initial: task.label ?? "",
            placeholder: "e.g. Movies, Linux ISOs", width: 240) {
            setLabel(value, task: task.id)
        }
    }

    func promptForRename(task: DownloadTask) {
        guard let newName = Self.promptText(
            title: "Rename “\(task.name)”",
            message: "Renames the download and its file on disk.",
            confirm: "Rename", initial: task.name) else { return }
        Task {
            let result = await manager.rename(task.id, to: newName)
            await MainActor.run {
                switch result {
                case .renamed(let name): toastNow("Renamed to “\(name)”")
                case .unchanged: break
                case .notFound: toastNow("That download no longer exists")
                case .unsupported: toastNow("Torrents can’t be renamed here")
                case .active: toastNow("Pause the download before renaming")
                case .ioError(let msg): toastNow("Couldn’t rename: \(msg)")
                }
            }
        }
    }

    func promptForBatchRename(tasks: [DownloadTask]) {
        let eligible = tasks.filter { $0.kind != .torrent && !$0.status.isActive }
        guard !eligible.isEmpty else { toastNow("Nothing eligible to rename"); return }
        guard let raw = Self.promptText(
            title: "Rename \(eligible.count) downloads",
            message: "Use “#” for a running number. The original extension is kept if you omit one.",
            confirm: "Rename All", initial: "File #",
            placeholder: "e.g. Episode #") else { return }
        let template = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return }
        let candidates = PromptParsing.batchRename(template: template, over: eligible.map(\.name))
        Task {
            var renamed = 0
            var failed = 0
            for (task, candidate) in zip(eligible, candidates) {
                switch await manager.rename(task.id, to: candidate) {
                case .renamed, .unchanged: renamed += 1
                default: failed += 1
                }
            }
            await MainActor.run {
                if failed == 0 {
                    toastNow("Renamed \(renamed) download\(renamed == 1 ? "" : "s")")
                } else {
                    toastNow("Renamed \(renamed), \(failed) couldn’t be renamed")
                }
            }
        }
    }

    func promptForTags(task: DownloadTask) {
        guard let value = Self.promptText(
            title: "Tags for “\(task.name)”",
            message: "Comma-separated. Leave empty to clear.",
            confirm: "Save", initial: task.allTags.joined(separator: ", "),
            placeholder: "e.g. work, urgent, linux") else { return }
        let tags = PromptParsing.tags(from: value)
        Task { await manager.setTags(tags, task: task.id) }
        toastNow(tags.isEmpty ? "Tags cleared" : "Tags updated")
    }

    func promptForNote(task: DownloadTask) {
        let alert = NSAlert()
        alert.messageText = "Note for “\(task.name)”"
        alert.informativeText = "Attach a free-form note. Leave empty to remove."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        let text = NSTextView(frame: scroll.bounds)
        text.string = task.note ?? ""
        text.isRichText = false
        text.font = .systemFont(ofSize: 12)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await manager.setNote(text.string, task: task.id) }
        toastNow(text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Note removed" : "Note saved")
    }

    func promptForRequestOptions(task: DownloadTask) {
        let alert = NSAlert()
        alert.messageText = "Request options for “\(task.name)”"
        alert.informativeText = "Sent only to the download’s own host. One header per line as “Name: value”."
        let container = NSStackView(frame: NSRect(x: 0, y: 0, width: 340, height: 150))
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        let refererLabel = NSTextField(labelWithString: "Referer")
        let referer = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        referer.stringValue = task.referer ?? ""
        referer.placeholderString = "https://example.com/page"
        let headersLabel = NSTextField(labelWithString: "Headers")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 84))
        let headersView = NSTextView(frame: scroll.bounds)
        headersView.string = (task.requestHeaders ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        headersView.isRichText = false
        headersView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = headersView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        container.addArrangedSubview(refererLabel)
        container.addArrangedSubview(referer)
        container.addArrangedSubview(headersLabel)
        container.addArrangedSubview(scroll)
        referer.widthAnchor.constraint(equalToConstant: 340).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 340).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let headers = PromptParsing.requestHeaders(from: headersView.string)
        Task {
            let dropped = await manager.setRequestOptions(referer: referer.stringValue,
                                                          headers: headers, task: task.id)
            await MainActor.run {
                if dropped.isEmpty {
                    toastNow("Request options saved")
                } else {
                    toastNow("Saved — ignored reserved header\(dropped.count == 1 ? "" : "s"): \(dropped.joined(separator: ", "))")
                }
            }
        }
    }

    var ffmpegAvailable: Bool { FFmpegService.isAvailable(override: settings.ffmpegPath) }

    @Published private(set) var managedPolicy: ManagedPolicy = ManagedPolicy.current()

    /// The portal runs off this copy, so without the re-apply the MDM kill switch waits for relaunch.
    func refreshManagedPolicy() {
        managedPolicy = ManagedPolicy.current()
        let manager = self.manager
        Task {
            await manager.refreshManagedPolicy()
            settings = await manager.currentSettings
            applyRemoteAccess()
        }
    }

    static let managedFootnote = "Managed by your organisation."

    func revealAuditLogFolder() {
        let manager = self.manager
        Task {
            guard let url = await manager.auditLogDirectory() else {
                await MainActor.run { self.toastNow("Audit log is off — nothing written yet") }
                return
            }
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }

    var ffmpegUnavailableReason: String? {
        FFmpegService.unavailableReason(override: settings.ffmpegPath)
    }

    var ffmpegResolutionSummary: String {
        FFmpegService.resolutionSummary(override: settings.ffmpegPath)
    }

    /// Not `@Published`: a nested ObservableObject doesn't forward changes — views observe it directly.
    let mediaJobs = MediaJobCenter()

    @Published private(set) var mediaLiveCount = 0

    private func syncMediaJobCenter() {
        mediaJobs.ffmpegOverride = settings.ffmpegPath
        mediaJobs.concurrencyLimit = max(1, settings.mediaConcurrency)
        mediaJobs.onFinish = { [weak self] job in
            self?.announceMediaJob(job)
        }
        mediaJobs.onLiveWorkChanged = { [weak self] in
            guard let self else { return }
            self.mediaLiveCount = self.mediaJobs.liveCount
            self.refreshActiveWorkGate()
            self.refreshDockProgress()
        }
        // The snapshot pump doesn't tick on an idle queue, so a lone conversion never reaches the Dock.
        mediaJobs.onTick = { [weak self] in
            self?.refreshDockProgress()
        }
    }

    private func refreshDockProgress() {
        dockProgress.update(with: tasks,
                            mediaBusyCount: mediaJobs.liveCount,
                            mediaFractions: mediaJobs.runningFractions)
    }

    private func refreshActiveWorkGate() {
        ActiveWorkGate.shared.hasActiveWork =
            reducerState.lastHadActiveWork
            || sftpTransfers.contains { $0.isActive }
            || mediaJobs.hasLiveWork
    }

    /// Shortest conversion worth a banner; below this the user was still looking at the menu.
    private static let mediaNotifyMinimumSeconds: TimeInterval = 20

    private func announceMediaJob(_ job: MediaJobCenter.Job) {
        let elapsed = (job.finishedAt ?? Date()).timeIntervalSince(job.startedAt)
        guard elapsed >= Self.mediaNotifyMinimumSeconds else { return }
        if settings.notifyOnlyWhenInactive, NSApp.isActive { return }
        switch job.state {
        case .finished(let url, _):
            guard settings.notifyOnCompleted else { return }
            NotificationService.notify(title: job.kind.finishedTitle,
                                       body: url.lastPathComponent,
                                       sound: settings.notificationSound)
        case .failed(let message):
            guard settings.notifyOnFailed else { return }
            NotificationService.notify(title: "Conversion failed",
                                       body: message, sound: settings.notificationSound)
        default:
            break
        }
    }

    func convertFile(task: DownloadTask, toExtension ext: String) {
        let input = URL(fileURLWithPath: task.savePath)
        if let rejection = mediaJobs.enqueue(input: input, kind: .convert(ext: ext)) {
            toastNow(rejection.message)
        }
    }

    func extractAudio(task: DownloadTask, format: AudioExtractionFormat) {
        let input = URL(fileURLWithPath: task.savePath)
        if let rejection = mediaJobs.enqueue(input: input, kind: .extractAudio(format: format)) {
            toastNow(rejection.message)
        }
    }

    func toastNow(_ message: String) {
        toastGeneration &+= 1
        let generation = toastGeneration
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toastGeneration == generation { toast = nil }
        }
    }

    func localized(_ key: String) -> String {
        L10n.string(key, language: settings.language)
    }
}
