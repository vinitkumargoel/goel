import Foundation
import SwiftUI
import AppKit
import Network
import GoelCore

/// Which sidebar entry is selected. Drives the list filter and the live counts.
enum SidebarFilter: Hashable {
    case all
    case active
    case paused
    case completed
    case seeding
    case type(FileType)
}

/// Columns the list can be sorted by.
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

/// The five detail-panel tabs.
enum DetailTab: String, CaseIterable, Identifiable {
    case general = "General"
    case details = "Details"
    case progress = "Progress"
    case files = "Files"
    case connections = "Connections"
    var id: String { rawValue }
}

/// The `@MainActor` bridge between SwiftUI and the `DownloadManager` actor.
///
/// It owns the manager, subscribes to its snapshot stream, and republishes the
/// task list and settings as `@Published` state so the views observe a single
/// source of truth. Every mutation funnels back through async manager calls so
/// the UI genuinely drives the core (adding a magnet spins up the mock torrent
/// engine, an http URL starts the real `HTTPEngine`, etc.).
@MainActor
final class AppViewModel: ObservableObject {

    // MARK: Published model

    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var settings = AppSettings() {
        didSet {
            // Keep the global palette in sync with the persisted theme so every
            // `Theme.accent`/`.green`/… call site resolves against the selected
            // named theme. Runs on load, on theme change, and on any settings
            // commit — cheap and idempotent.
            let selected = AppTheme(settingsValue: settings.theme)
            if ThemePalette.current != selected {
                ThemePalette.current = selected
            }
        }
    }

    /// The filtered + sorted list the center view renders. Memoized: recomputed
    /// only when an input changes, not O(n log n) on every SwiftUI `body` pass.
    @Published private(set) var visibleTasks: [DownloadTask] = []

    /// Non-nil when on-disk persistence is degraded/unavailable, so the UI can
    /// warn the user that downloads/settings may not survive relaunch.
    @Published var persistenceWarning: String?

    /// Live network interfaces for the aggregation settings list.
    @Published private(set) var networkAdapters: [NetworkAdapter] = []

    /// Why multi-path is currently inactive (nil when active).
    @Published private(set) var aggregationInactiveReason: AggregationPolicy.SinglePathReason?

    /// Adapters that would participate if multi-path is on.
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

    // MARK: Published view state

    /// The full multi-selection set. A row highlights when its id is contained;
    /// the toolbar's bulk-select menu (all / none / completed) drives it.
    @Published var selection: Set<DownloadTask.ID> = []

    /// The "primary" row within ``selection`` — the one whose details the detail
    /// panel shows. Tracks the most recently clicked/added row, or `nil` for the
    /// empty-selection state.
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

    /// A file playing in the built-in AVKit player, or nil when the player is closed.
    @Published var playerItem: PlayerItem?

    /// One media file opened in the in-app player.
    struct PlayerItem: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
    }

    // MARK: SFTP servers

    /// Saved SFTP servers shown in the sidebar's "Servers" group. Mutated only
    /// through the `AppViewModel+SFTP` helpers.
    @Published var servers: [SFTPConnection] = []

    /// The server currently being browsed. When non-nil the main pane shows the
    /// SFTP file browser instead of the download list.
    @Published var selectedServer: SFTPConnection.ID?

    /// The connection open in the add/edit sheet (nil when adding a new one).
    @Published var editingServer: SFTPConnection?
    @Published var isServerEditorPresented: Bool = false

    // MARK: SFTP transfers (app-wide center — see AppViewModel+SFTPTransfers)

    /// Uploads and browser-initiated downloads, owned here (not by the browser
    /// view) so they survive closing/switching the server browser and stay
    /// cancellable. Rendered by the browser's transfer strip and the status-bar
    /// popover. Mutated only through the `AppViewModel+SFTPTransfers` helpers.
    @Published var sftpTransfers: [SFTPTransfer] = []

    /// A pending name-collision prompt, raised before an upload would overwrite
    /// remote files and resolved by ``SFTPUploadConflictSheet``. `nil` when idle.
    @Published var sftpUploadConflicts: SFTPUploadConflictRequest?

    /// Bumped whenever a transfer mutates a remote directory, so a browser showing
    /// that server re-lists to reflect the change.
    @Published var sftpMutationTick: Int = 0

    /// The running Task + cancel flag for each in-flight transfer, keyed by id.
    /// Retained here (not by any view) so a transfer outlives the browser; the
    /// entry is dropped when the transfer settles.
    var sftpTransferTasks: [UUID: (task: Task<Void, Never>, cancel: CancelFlag)] = [:]

    /// In-flight per-file byte counts for a folder upload (transfer id → file
    /// index → bytes). A folder now uploads several files at once, so completions
    /// arrive out of order; summing this map yields the row's monotonic aggregate.
    /// Cleared when the transfer settles.
    var sftpFolderBytes: [UUID: [Int: Int64]] = [:]

    // MARK: Speed history (sparklines)

    /// One second of aggregate throughput.
    struct SpeedSample: Equatable {
        var down: Double
        var up: Double
    }

    /// The last ~2 minutes of global throughput, sampled at 1 Hz.
    @Published private(set) var globalSpeedHistory: [SpeedSample] = []

    /// Combined ↓/↑ throughput for the menu-bar status item and the bottom
    /// status bar, refreshed on the sampler's cadence. Both read *this* (not the
    /// live raw sums) so their labels update ~2×/sec and never flicker.
    @Published private(set) var displayedCombinedSpeed = SpeedSample(down: 0, up: 0)

    /// Per-task history for the detail panel's sparkline (active tasks only).
    private(set) var taskSpeedHistory: [DownloadTask.ID: [SpeedSample]] = [:]

    /// The ↓/↑ throughput each task's speed *label* should display, refreshed by
    /// ``takeSpeedSample()``. The values themselves are already ~3 s window
    /// averages (``SpeedMeter``, applied in the manager); this map additionally
    /// pins the *refresh cadence* to the sampler's tick, so labels don't redraw
    /// on every 10 Hz model publish.
    @Published private(set) var displayedTaskSpeed: [DownloadTask.ID: SpeedSample] = [:]

    /// The ↓/↑ speed the UI should show for `task`: the sampled value when one
    /// exists, else the live value (covers a task's first moments, before the
    /// sampler has run for it).
    func displaySpeed(for task: DownloadTask) -> SpeedSample {
        displayedTaskSpeed[task.id] ?? SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed)
    }

    private static let speedHistoryCap = 120
    /// The display refresh cadence: labels update twice a second. History rings
    /// stay at 1 Hz (every other tick) so the sparklines keep their time span.
    private static let speedRefreshNanos: UInt64 = 500_000_000
    private var speedSampleTick = 0
    private var speedSampler: Task<Void, Never>?

    /// Light / Dark / System, derived from (and persisted through) the core
    /// ``AppSettings/theme`` string so the choice survives relaunch. The setter
    /// commits via ``update(_:)`` like every other persisted preference.
    var theme: AppTheme {
        get { AppTheme(settingsValue: settings.theme) }
        set { update { $0.theme = newValue.settingsValue } }
    }

    /// The **web portal's** theme, deliberately independent of ``theme`` (the local
    /// look). Persisted through ``AppSettings/remoteTheme`` and used only to seed
    /// the browser's default appearance — setting it never touches
    /// ``ThemePalette/current``, so the desktop and the web run their own themes.
    var remoteTheme: AppTheme {
        get { AppTheme(settingsValue: settings.remoteTheme) }
        set { update { $0.remoteTheme = newValue.settingsValue } }
    }

    /// Set (or clear) the web portal password. The plaintext is hashed with a
    /// random salt and never persisted directly; an empty string clears it.
    func setRemotePassword(_ plain: String) {
        let hash = RemotePassword.hash(plain)
        update { $0.remotePasswordHash = hash }
    }

    /// Whether a web portal password has been set.
    var hasRemotePassword: Bool { !settings.remotePasswordHash.isEmpty }

    /// Where the detail panel is docked (right edge vs bottom edge), derived from
    /// and persisted through ``AppSettings/detailPanelPosition`` so the choice
    /// survives relaunch. The setter commits via ``update(_:)`` — which reflects
    /// the new value locally this frame before the actor round-trip — so the panel
    /// re-docks immediately and stays put until the user flips it again.
    var detailPanelPosition: DetailPanelPosition {
        get { DetailPanelPosition(settingsValue: settings.detailPanelPosition) }
        set { update { $0.detailPanelPosition = newValue.settingsValue } }
    }

    /// Flip the panel between the right and bottom docks (used by the toggle on
    /// the panel header).
    func toggleDetailPanelPosition() {
        detailPanelPosition = detailPanelPosition == .right ? .bottom : .right
    }

    /// A transient banner shown after notable actions (mirrors the demo toasts).
    @Published var toast: String?

    /// A pending confirmation rendered by the app's own ``ConfirmDialogView`` at
    /// the window root (replacing the system `.confirmationDialog`). `nil` when
    /// nothing is being confirmed.
    @Published var confirmRequest: ConfirmRequest?

    /// The payload for the custom confirm dialog: its copy, the destructive flag
    /// (drives the red styling), and the action to run when the user confirms.
    struct ConfirmRequest: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var confirmTitle: String
        var isDestructive: Bool
        var onConfirm: () -> Void
    }

    /// Raise the custom confirm dialog. The closure runs only if the user taps
    /// the confirm button.
    func requestConfirm(title: String, message: String, confirmTitle: String,
                        destructive: Bool = false, onConfirm: @escaping () -> Void) {
        confirmRequest = ConfirmRequest(title: title, message: message,
                                        confirmTitle: confirmTitle,
                                        isDestructive: destructive, onConfirm: onConfirm)
    }

    /// Feedback destined for the **Settings window**. Settings is a separate
    /// scene that does NOT render the main window's toast/confirm overlays, so a
    /// `toast` or `confirmRequest` raised from a settings pane is invisible to a
    /// user who is looking at Settings (the button appears to do nothing). Panes
    /// route errors and confirmations through here instead, and `SettingsView`
    /// presents it as a native alert on the Settings window itself.
    @Published var settingsAlert: SettingsAlert?

    struct SettingsAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        /// `nil` = informational (a single OK button); non-nil = a confirmation
        /// whose button runs `onConfirm`.
        var confirmTitle: String?
        var isDestructive = false
        var onConfirm: (() -> Void)?
    }

    /// Show an informational / error pop-up on the Settings window.
    func settingsMessage(_ title: String, _ message: String) {
        settingsAlert = SettingsAlert(title: title, message: message)
    }

    /// Raise a confirmation pop-up on the Settings window. `onConfirm` runs only
    /// if the user taps the confirm button.
    func settingsConfirm(title: String, message: String, confirmTitle: String,
                         destructive: Bool = false, onConfirm: @escaping () -> Void) {
        settingsAlert = SettingsAlert(title: title, message: message,
                                      confirmTitle: confirmTitle,
                                      isDestructive: destructive, onConfirm: onConfirm)
    }

    /// A copied link the clipboard monitor is offering to download, shown as an
    /// actionable banner. `nil` when there is nothing to suggest.
    @Published var clipboardSuggestion: String?

    // MARK: Core

    private let manager: DownloadManager
    private var updatesTask: Task<Void, Never>?

    /// Watches the pasteboard for copied download links (Tier-1 convenience).
    private var clipboardMonitor: ClipboardMonitor?

    /// Watches the network path and reports expensive/constrained transitions
    /// to the manager's pause-on-metered policy.
    private var pathMonitor: NWPathMonitor?

    /// While the Aggregation settings pane is open, poll interfaces so new
    /// adapters appear without waiting for a path status flip.
    private var aggregationLiveTask: Task<Void, Never>?
    private var aggregationWatchCount = 0
    private var lastVPNActive = false
    private var networkChangeObserver: NSObjectProtocol?

    /// The embedded remote-control HTTP server (Settings → Remote Access).
    private var remoteServer: RemoteControlServer?

    /// The remote settings the running server was started with, so only a real
    /// change restarts it. A struct (not a tuple) because it now carries more
    /// than six fields and needs synthesized `Equatable`.
    private struct RemoteDesired: Equatable {
        var enabled: Bool
        var port: Int
        var lan: Bool
        var token: String
        var requireAuth: Bool
        var username: String
        var passwordHash: String
        var readOnly: Bool
        var theme: String
        var sessionMinutes: Int
    }
    private var remoteConfig: RemoteDesired?

    /// The last link the clipboard monitor surfaced, so the same copy isn't
    /// offered twice (and a dismissed suggestion stays dismissed).
    private var lastClipboardHandled: String?

    /// Whether the one-time launch auto-select has already run. Once it has,
    /// clearing the selection ("Select none") sticks instead of snapping back to
    /// the first row on the next snapshot.
    private var hasAutoSelected = false

    /// Monotonic token identifying the most recent ``toastNow`` invocation, so a
    /// later toast's timer never gets pre-empted by an earlier one that happens to
    /// carry identical text.
    private var toastGeneration = 0

    /// The carry-over state for the snapshot pump — the notification-diff baselines
    /// and the queue-drain edge — folded by the pure ``SnapshotReducer`` each tick.
    /// Replaces the four separate, order-dependent mutable fields this used to keep.
    private var reducerState = ReducerState()

    /// Finder-visible per-file progress (the Safari-style pie on the file).
    private let fileProgress = FileProgressPublisher()

    /// Dock-icon badge + aggregate progress bar.
    private let dockProgress = DockProgressService()

    /// The OS side-effect boundary (posting banners + the irreversible drain
    /// action), injected so the pure ``SnapshotReducer`` decision can be exercised
    /// without a real `NSApp.terminate` / `pmset` / AppleScript.
    private let system: SystemActions

    /// The live instance, for entry points that can't be injected (the
    /// AppleScript command classes). Weak: scripting must never keep a
    /// discarded view model alive.
    static private(set) weak var shared: AppViewModel?

    init(system: SystemActions = LiveSystemActions()) {
        // File-backed persistence under Application Support, falling back to an
        // ephemeral in-memory store if the directory can't be created — and
        // surfacing a warning when it does, rather than silently losing state.
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

    /// Begin observing the manager. Called once from the root view's `.task`.
    func start() async {
        guard updatesTask == nil else { return }
        await manager.restore()
        settings = await manager.currentSettings
        // Start watching the clipboard for copied download links.
        let monitor = ClipboardMonitor(isEnabled: settings.clipboardMonitorEnabled) { [weak self] text in
            self?.handleClipboardChange(text)
        }
        monitor.start()
        clipboardMonitor = monitor
        // Report expensive (hotspot) / constrained (Low Data Mode) transitions
        // so the pause-on-metered settings can hold and release the queue.
        let netMonitor = NWPathMonitor()
        let core = self.manager
        netMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            // VPN/tunnel iface up (utun/ipsec/…) — separate from multi-path adapter
            // list, which intentionally excludes tunnels.
            let vpnActive = AdapterDirectory.hasActiveVPNInterface()
            Task {
                await core.applyNetworkPolicy(expensive: expensive, constrained: constrained)
                await core.setVPNDefaultRouteActive(vpnActive)
                await MainActor.run { self?.refreshAggregationState() }
            }
        }
        netMonitor.start(queue: DispatchQueue(label: "goel.network-path"))
        pathMonitor = netMonitor
        // macOS posts this when interfaces/addresses change — often faster than
        // waiting for NWPath "satisfied" status to flip.
        networkChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.system.config.network_change"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAggregationState()
        }
        await refreshAggregationState()
        startSpeedSampler()
        applyRemoteAccess()
        SparkleUpdaterService.shared.startIfConfigured()
        if !SparkleUpdaterService.shared.isConfigured, settings.autoCheckUpdates {
            Task { [weak self] in
                guard let self else { return }
                if case let .available(version, url) = await UpdateChecker.check(feedURL: self.settings.updateFeedURL) {
                    self.offerUpdate(version: version, url: url)
                }
            }
        }
        // Downloads handed over from outside the UI: URL scheme, magnet links,
        // .torrent double-clicks, the Services menu, and the drop basket.
        // Registering also drains anything that arrived before we were ready
        // (a cold launch triggered by a link/file open).
        NotificationCenter.default.addObserver(
            forName: ExternalAdd.notification, object: nil, queue: .main
        ) { [weak self] note in
            guard let box = note.object as? ExternalAdd.PayloadBox else { return }
            Task { @MainActor [weak self] in
                self?.handleExternalAdd(box.payload)
            }
        }
        ExternalAdd.drainPending { handleExternalAdd($0) }
        // Anything the browser extension spooled while we weren't running
        // (including dev builds, where the URL-scheme poke can't reach us).
        drainBrowserSpool()
        // Prime notification authorization so persisted "notify on completed/failed"
        // preferences can actually deliver banners after a relaunch (not just after
        // the user re-toggles a switch).
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
                    self.tasks = snapshot
                    self.recomputeVisible()
                    // Auto-select the first visible row exactly once, at launch, so
                    // "Select none" sticks and the empty-detail state stays reachable
                    // while downloads are active.
                    if self.primarySelection == nil && !self.hasAutoSelected {
                        if let first = self.visibleTasks.first?.id {
                            self.hasAutoSelected = true
                            self.primarySelection = first
                            self.selection = [first]
                        }
                    }
                    // One pure fold decides notifications + the drain edge from the
                    // same prior state — no order-dependence between the two passes.
                    self.pump(snapshot)
                    self.fileProgress.update(with: snapshot) { [weak self] id in
                        self?.pause(id)
                    }
                    self.dockProgress.update(with: snapshot)
                    if let warning { self.persistenceWarning = warning }
                }
            }
        }
    }

    // MARK: Derived collections

    /// Recompute the memoized ``visibleTasks``. Called when `tasks` updates or any
    /// filter/search/sort input changes — never per render.
    private func recomputeVisible() {
        var list = tasks.filter { matches($0, filter) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { task in
                task.name.lowercased().contains(q)
                    || task.allTags.contains { $0.lowercased().contains(q) }
                    || (task.note?.lowercased().contains(q) ?? false)
            }
        }
        visibleTasks = list.sorted(by: sortComparator)
    }

    private func matches(_ task: DownloadTask, _ filter: SidebarFilter) -> Bool {
        switch filter {
        case .all: return true
        case .active: return task.status.isActive
        case .paused: return task.status == .paused
        case .completed: return task.status == .completed
        case .seeding: return task.status == .seeding
        case .type(let t): return task.fileType == t
        }
    }

    private func sortComparator(_ a: DownloadTask, _ b: DownloadTask) -> Bool {
        let result: Bool
        switch sortKey {
        case .index, .added:
            result = a.addedAt < b.addedAt
        case .name:
            result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case .size:
            result = (a.totalBytes ?? 0) < (b.totalBytes ?? 0)
        case .status:
            result = Self.statusOrder(a.status) < Self.statusOrder(b.status)
        case .downloadSpeed:
            result = a.downloadSpeed < b.downloadSpeed
        case .uploadSpeed:
            result = a.uploadSpeed < b.uploadSpeed
        }
        return sortAscending ? result : !result
    }

    private static func statusOrder(_ s: DownloadStatus) -> Int {
        switch s {
        case .downloading: return 0
        case .verifying: return 0
        case .requestingMetadata: return 1
        case .seeding: return 2
        case .queued: return 3
        case .paused: return 4
        case .failed: return 5
        case .completed: return 6
        }
    }

    func count(for filter: SidebarFilter) -> Int {
        tasks.filter { matches($0, filter) }.count
    }

    var selectedTask: DownloadTask? {
        guard let primarySelection else { return nil }
        return tasks.first { $0.id == primarySelection }
    }

    // Row selection (isSelected, selectOnly, toggleSelection, selectAll,
    // selectCompleted, selectNone, visibleNeighbor) lives in
    // `AppViewModel+Selection.swift`.

    // MARK: Aggregate stats (status bar)

    var totalDownloadSpeed: Double { tasks.reduce(0) { $0 + $1.downloadSpeed } }
    var totalUploadSpeed: Double { tasks.reduce(0) { $0 + $1.uploadSpeed } }

    /// Live throughput from the SFTP transfer center (browser uploads/downloads),
    /// which runs outside the download-manager task list. Only in-flight rows
    /// count.
    var sftpUploadSpeed: Double {
        sftpTransfers.reduce(0) { $0 + ($1.isActive && $1.direction == .upload ? $1.speed : 0) }
    }
    var sftpDownloadSpeed: Double {
        sftpTransfers.reduce(0) { $0 + ($1.isActive && $1.direction == .download ? $1.speed : 0) }
    }

    /// Grand totals shown in the status bar and menu-bar item: the download queue
    /// plus the SFTP transfer center, so an SFTP upload registers in the ↑ total.
    var combinedDownloadSpeed: Double { totalDownloadSpeed + sftpDownloadSpeed }
    var combinedUploadSpeed: Double { totalUploadSpeed + sftpUploadSpeed }

    var preferredColorScheme: ColorScheme? { theme.colorScheme }

    // MARK: Actions — all bridge to the actor

    func add(rawLines: String, saveDirectory: String?, priority: FilePriority,
             expectedChecksum: Checksum? = nil) {
        var sources = Self.expandedLines(rawLines).compactMap(Self.parseSource)
        // A metalink URL describes downloads (mirrors + checksums) — fetch and
        // expand it rather than downloading the XML itself.
        let metalinks = sources.filter(Self.isMetalink)
        sources.removeAll(where: Self.isMetalink)
        for case .url(let metalink) in metalinks {
            importMetalink(metalink, saveDirectory: saveDirectory, priority: priority)
        }
        guard !sources.isEmpty else {
            if metalinks.isEmpty { toastNow("Enter a URL or magnet link first") }
            return
        }
        // Surface duplicates instead of silently no-op-ing (the manager dedups by
        // source identity, so re-adding an existing task would just be swallowed).
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
        // A checksum only makes sense for a single file — never apply one supplied
        // alongside a multi-line batch to every download.
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

    /// Split pasted text into lines and expand the `file[01-20].zip` / `{a,b,c}`
    /// batch shorthand, capped so a hostile range can't flood the queue.
    static func expandedLines(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { BatchExpander.expand($0) }
    }

    /// The existing task (any status) matching a source's identity, so the add
    /// flow can tell the user instead of silently deduplicating.
    func existingDuplicate(of source: DownloadSource) -> DownloadTask? {
        tasks.first { $0.source.dedupKey == source.dedupKey }
    }

    /// Whether a source points at a metalink document rather than a payload.
    static func isMetalink(_ source: DownloadSource) -> Bool {
        guard case .url(let url) = source else { return false }
        return ["metalink", "meta4"].contains(url.pathExtension.lowercased())
    }

    /// Fetch a metalink document and add every file it describes — primary URL
    /// plus mirrors, published size ignored (probed live), checksum adopted.
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

    // MARK: Two-step add (resolve metadata, then confirm)

    /// The parseable source locators in `rawLines` (batch patterns expanded), in
    /// order. Used to decide between the single-item confirm flow and a batch add.
    func parsedSources(in rawLines: String) -> [DownloadSource] {
        Self.expandedLines(rawLines).compactMap(Self.parseSource)
    }

    /// Resolve a single source's metadata for the confirmation screen. Returns
    /// nil only if the line doesn't parse into a valid source.
    func resolveMetadata(for line: String, saveDirectory: String?) async -> DownloadPreview? {
        guard let source = Self.parseSource(line) else { return nil }
        return await manager.resolveMetadata(for: source, saveDirectory: saveDirectory)
    }

    /// Commit a previewed download with the destination / priority / checksum the
    /// user chose on the confirmation screen.
    func confirm(_ preview: DownloadPreview, saveDirectory: String?,
                 priority: FilePriority, checksum: Checksum?, startAt: Date? = nil,
                 mirrors: [String]? = nil, deselectedFileIDs: [Int]? = nil) {
        // The manager dedups by source identity — starting an exact duplicate is
        // a no-op, so say that instead of a misleading "Added".
        guard existingDuplicate(of: preview.source) == nil else {
            toastNow("Already in your list")
            filter = .all
            return
        }
        // A checksum only applies to a single-file HTTP/HLS download.
        let checksum = preview.kind == .torrent ? nil : checksum
        let source = preview.source
        // Mirrors only make sense for direct HTTP downloads.
        let mirrors = preview.kind == .http ? mirrors : nil
        // Pre-add file deselection only applies to (multi-file) torrents.
        let skipFiles = preview.kind == .torrent ? deselectedFileIDs : nil
        // Carry the metadata already gathered on the add screen into the task so
        // the download doesn't re-derive it. For torrents the size/file list come
        // from libtorrent's own handle (a seeded value would flicker against the
        // poller's pre-metadata state), so only the resolved name is seeded there.
        let seededBytes = preview.kind == .torrent ? nil : preview.totalBytes
        let seededFiles = preview.kind == .torrent ? [] : preview.files
        Task {
            await manager.add(source: source, saveDirectory: saveDirectory,
                              priority: priority, expectedChecksum: checksum,
                              scheduledAt: startAt, mirrors: mirrors,
                              suggestedName: preview.suggestedName,
                              totalBytes: seededBytes, files: seededFiles,
                              deselectedFileIDs: skipFiles)
        }
        if let startAt {
            let formatter = RelativeDateTimeFormatter()
            toastNow("Will start \(formatter.localizedString(for: startAt, relativeTo: Date()))")
        } else {
            toastNow("Added to queue")
        }
        filter = .all
    }

    // MARK: Clipboard capture

    /// Called by the clipboard monitor when new text is copied. Surfaces the first
    /// downloadable link as a suggestion banner — unless it's the same link we
    /// already offered, or it's already in the queue.
    func handleClipboardChange(_ text: String) {
        let link = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { Self.parseSource($0) != nil }
        guard let link, link != lastClipboardHandled, let source = Self.parseSource(link) else { return }
        if tasks.contains(where: { $0.source.dedupKey == source.dedupKey }) { return }
        lastClipboardHandled = link
        clipboardSuggestion = link
    }

    /// Add the suggested clipboard link and clear the banner.
    func acceptClipboardSuggestion() {
        guard let link = clipboardSuggestion else { return }
        clipboardSuggestion = nil
        add(rawLines: link, saveDirectory: nil, priority: .normal)
    }

    /// Dismiss the suggestion without adding it (it won't be offered again).
    func dismissClipboardSuggestion() {
        clipboardSuggestion = nil
    }

    // MARK: External adds

    /// Handle a download handed over from outside the UI. Web-triggerable
    /// sources (`goeldownloader://` links) surface as the suggestion banner so
    /// the user confirms; explicit user actions queue directly. Local
    /// `.torrent` file opens construct the source directly — the remote-input
    /// parser deliberately rejects `file:` URLs.
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

    /// Queue everything the browser extension spooled through the
    /// native-messaging host. The spool contents were validated by the host
    /// and can only be written by local processes, so no confirmation banner —
    /// the user already clicked "download" in their browser.
    private func drainBrowserSpool() {
        // Re-validate the scheme allowlist here too: the spool file is
        // user-only, but auto-adding without confirmation must never initiate an
        // authenticated `sftp:`/`ftp:` connection on a web page's behalf.
        let locators = BrowserSpool.drain().filter {
            DownloadSource.parse($0)?.isBrowserCaptureSafe == true
        }
        guard !locators.isEmpty else { return }
        add(rawLines: locators.joined(separator: "\n"), saveDirectory: nil, priority: .normal)
    }

    /// Delegates to the core parser, which enforces the scheme allowlist
    /// (http/https/magnet/.torrent only).
    static func parseSource(_ line: String) -> DownloadSource? {
        DownloadSource.parse(line)
    }

    func pause(_ id: DownloadTask.ID) { Task { await manager.pause(id) } }
    func resume(_ id: DownloadTask.ID) { Task { await manager.resume(id) } }
    func remove(_ id: DownloadTask.ID, deleteData: Bool) {
        let name = tasks.first { $0.id == id }?.name
        // Move the primary to the adjacent visible row *before* the snapshot drops
        // the deleted task, so selection lands on a neighbour that's actually in
        // the filtered list rather than jumping to the raw-first task.
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
        // Failed tasks need the dedicated retry path; resume() ignores non-paused.
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
            // Toast after the refresh so it reflects the committed settings.
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

    /// Commit a settings change. Mutates a copy of ``settings``, pushes it through
    /// the manager (which persists it and re-applies the engine configs), then
    /// republishes the committed value and fires the app-layer side effects the
    /// core deliberately doesn't own — login-item registration and notification
    /// authorization. The manager round-trip runs off the main actor so editing a
    /// settings field never blocks the UI.
    /// Refresh adapter list + multi-path inactive reason (Settings UI + engine).
    /// Only republishes / re-applies engines when something actually changed so a
    /// 1 Hz live poll stays cheap and the list can update the moment a NIC appears.
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

        // Engine only needs to know when the usable bind set / VPN policy changes.
        if adaptersChanged || vpnChanged {
            Task {
                await manager.setVPNDefaultRouteActive(vpn)
                await manager.reapplyEngineConfigsPublic()
            }
        }
    }

    /// Call while the Aggregation settings pane is visible so new networks show up
    /// immediately (path monitor alone often misses hotplug until status changes).
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

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        // Skip redundant commits. `@Published settings` fires on every assignment
        // regardless of equality, so a no-op write (e.g. SwiftUI writing a control's
        // current value back through its binding) would needlessly re-persist,
        // re-apply engine configs, and re-publish — which, for scene-level bindings
        // like the menu-bar toggle, can spin into an update loop. A true no-op is a
        // no-op.
        guard copy != settings else { return }
        let launchChanged = copy.launchAtLogin != settings.launchAtLogin
        let notificationsNewlyWanted =
            (copy.notifyOnAdded || copy.notifyOnCompleted || copy.notifyOnFailed) &&
            !(settings.notifyOnAdded || settings.notifyOnCompleted || settings.notifyOnFailed)
        // Reflect the change locally first so bound controls (e.g. the live theme
        // picker) update this frame, then commit through the actor.
        settings = copy
        clipboardMonitor?.isEnabled = copy.clipboardMonitorEnabled
        let committed = copy
        Task {
            settings = await manager.apply { $0 = committed }
            refreshAggregationState()
        }
        if launchChanged { LoginItemService.setEnabled(copy.launchAtLogin) }
        if notificationsNewlyWanted { NotificationService.requestAuthorization() }
        applyRemoteAccess()
        // Immediate local refresh for adapter toggles (engine re-apply is async).
        networkAdapters = AdapterDirectory.enumerate()
        aggregationInactiveReason = DownloadManager.aggregationSinglePathReason(
            settings: settings,
            vpnDefaultRoute: AdapterDirectory.hasActiveVPNInterface(),
            adapters: networkAdapters)
    }

    /// Toggle an adapter id in the aggregation multi-select list.
    func toggleAggregationAdapter(_ bsdName: String) {
        update { s in
            var ids = Set(s.aggregationAdapterIds)
            if ids.contains(bsdName) { ids.remove(bsdName) }
            else { ids.insert(bsdName) }
            s.aggregationAdapterIds = ids.sorted()
        }
    }

    // MARK: Remote access

    /// Start/stop/restart the embedded remote-control server to match the
    /// current settings. Idempotent — only a real config change restarts it.
    private func applyRemoteAccess() {
        let desired = RemoteDesired(
            enabled: settings.remoteAccessEnabled,
            port: settings.remotePort,
            lan: settings.remoteAllowLAN,
            token: settings.remoteToken,
            requireAuth: settings.remoteRequireAuth,
            username: settings.remoteUsername,
            passwordHash: settings.remotePasswordHash,
            readOnly: settings.remoteReadOnly,
            theme: settings.remoteTheme,
            sessionMinutes: settings.remoteSessionMinutes)
        guard remoteConfig != desired else { return }
        remoteConfig = desired
        let server = remoteServer ?? RemoteControlServer(manager: manager)
        remoteServer = server
        Task {
            if desired.enabled {
                let config = RemoteRouter.Config(
                    token: desired.token, requireAuth: desired.requireAuth,
                    readOnly: desired.readOnly, theme: desired.theme, username: desired.username)
                await server.start(port: UInt16(clamping: desired.port), allowLAN: desired.lan,
                                   config: config, passwordHash: desired.passwordHash,
                                   sessionMinutes: desired.sessionMinutes)
            } else {
                await server.stop()
            }
        }
    }

    // MARK: Updates

    /// Manual "Check for Updates…". Sparkle handles it (with its own UI) in
    /// packaged builds configured with an appcast; everything else uses the
    /// built-in HTTPS release-feed checker.
    func checkForUpdates() {
        if SparkleUpdaterService.shared.checkForUpdates() { return }
        let feed = settings.updateFeedURL
        Task { [weak self] in
            guard let self else { return }
            switch await UpdateChecker.check(feedURL: feed) {
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

    /// Open the downloaded payload with its default app (the media player for
    /// video). Multi-file torrents open their largest wanted file — the movie,
    /// not the .nfo (libtorrent file paths are relative to the save directory).
    func openFile(_ task: DownloadTask) {
        NSWorkspace.shared.open(URL(fileURLWithPath: task.primaryFilePath))
    }

    /// Open a finished media file in the built-in AVKit player. Multi-file
    /// torrents play their largest wanted file, mirroring ``openFile(_:)``.
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

    // MARK: Snapshot pump

    /// Fold the manager's snapshot into user-visible effects: run the pure
    /// ``SnapshotReducer`` (notification diff + the one-shot queue-drain edge)
    /// against the carried ``reducerState``, then apply its decision through the
    /// injected ``SystemActions``. The reducer removes the old order-dependence
    /// between the drain check and the notification pass — both read the same
    /// prior state — and makes the destructive shutdown edge testable in Core.
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
        // Drain first (it may terminate the app), then the banners — matching the
        // original checkQueueDrained → emitNotifications ordering.
        if let intent = output.drainIntent {
            update { $0.autoShutdownAction = "none" }   // one-shot: never fire twice
            system.perform(intent)
        }
        system.post(output.notifications, sound: settings.notificationSound)
    }

    // MARK: Speed sampling

    /// Sample aggregate and per-task throughput on a steady cadence for the
    /// speed labels (every tick) and sparklines (1 Hz). Runs for the app's
    /// lifetime; the ring caps keep memory flat.
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
        // Fully idle (no active task/transfer, a flat history, and a zeroed
        // combined readout): skip the sample so the @Published writes don't
        // re-render the whole app twice a second while it sits doing nothing.
        let hasActive = tasks.contains { $0.status.isActive } || sftpTransfers.contains { $0.isActive }
        if !hasActive,
           globalSpeedHistory.allSatisfy({ $0 == SpeedSample(down: 0, up: 0) }),
           displayedCombinedSpeed == SpeedSample(down: 0, up: 0) {
            return
        }
        speedSampleTick &+= 1
        // Histories advance at 1 Hz (every other tick) so the graphs keep
        // their time span; labels refresh every tick.
        let recordHistory = speedSampleTick.isMultiple(of: 2)
        // The status-bar / menu-bar combined value: download queue + SFTP transfers.
        displayedCombinedSpeed = SpeedSample(down: combinedDownloadSpeed, up: combinedUploadSpeed)
        var sample = SpeedSample(down: 0, up: 0)
        for task in tasks {
            sample.down += task.downloadSpeed
            sample.up += task.uploadSpeed
            // The calm value the speed labels read (all tasks, not just
            // active, so a just-finished row settles to its final number).
            displayedTaskSpeed[task.id] = SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed)
            guard recordHistory, task.status.isActive else { continue }
            var history = taskSpeedHistory[task.id] ?? []
            history.append(SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed))
            if history.count > Self.speedHistoryCap { history.removeFirst() }
            taskSpeedHistory[task.id] = history
        }
        // Drop history for tasks that no longer exist (kept for paused ones so
        // a brief pause doesn't wipe the graph).
        let known = Set(tasks.map(\.id))
        taskSpeedHistory = taskSpeedHistory.filter { known.contains($0.key) }
        displayedTaskSpeed = displayedTaskSpeed.filter { known.contains($0.key) }
        if recordHistory {
            globalSpeedHistory.append(sample)
            if globalSpeedHistory.count > Self.speedHistoryCap { globalSpeedHistory.removeFirst() }
        }
    }

    /// Fetch the persisted transfer statistics for the Statistics sheet.
    func fetchStats() async -> TransferStats {
        await manager.currentStats
    }

    // MARK: Download history

    /// Fetch the archived completed downloads for the History sheet.
    func fetchHistory() async -> [HistoryEntry] {
        await manager.history()
    }

    /// Queue an archived entry's source again.
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

    /// Write the given history entries as CSV (spreadsheet-friendly archive).
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

    // MARK: Scheduled starts

    /// Set (or clear) a one-shot start time on a task.
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

    // Queue automation (auto-shutdown): the drain-edge DECISION now lives in the
    // pure `SnapshotReducer` (folded by `pump`), and the irreversible OS EFFECT in
    // `LiveSystemActions.perform(_:)` behind the `SystemActions` port.

    // MARK: Full-fidelity backup (JSON)

    /// Write the settings + full task list (progress, resume cursors and all) to
    /// `url`. The JSON counterpart of the locator-only text export.
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

    /// Import a backup produced by ``exportBackup(to:)``: adopts its settings
    /// and merges its tasks (existing sources are skipped; restored tasks come
    /// back paused).
    func importBackup(from url: URL) {
        Task {
            do {
                let data = try Data(contentsOf: url)
                let added = try await manager.importEnvelope(data)
                settings = await manager.currentSettings
                toastNow(added > 0 ? "Imported \(added) download\(added == 1 ? "" : "s")"
                                   : "Nothing new to import")
            } catch {
                toastNow("Import failed — not a valid backup file")
            }
        }
    }

    // MARK: Per-task controls

    /// Toggle sequential (in-order) download for a torrent so media can be
    /// previewed while transferring.
    func setSequential(_ sequential: Bool, task id: DownloadTask.ID) {
        Task { await manager.setSequential(sequential, task: id) }
        toastNow(sequential ? "Sequential download on" : "Sequential download off")
    }

    /// Cap one task's download speed (nil/0 = uncapped). Takes effect when the
    /// task next starts or resumes.
    func setTaskSpeedLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) {
        Task { await manager.setTaskSpeedLimit(bytesPerSec, task: id) }
        if let bytesPerSec, bytesPerSec > 0 {
            toastNow("Limited to \(Double(bytesPerSec).speedString) — applies on next start")
        } else {
            toastNow("Per-download limit removed")
        }
    }

    /// Cap one torrent's upload (seeding) rate. Takes effect immediately.
    func setTaskUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) {
        Task { await manager.setTaskUploadLimit(bytesPerSec, task: id) }
        if let bytesPerSec, bytesPerSec > 0 {
            toastNow("Upload limited to \(Double(bytesPerSec).speedString)")
        } else {
            toastNow("Upload limit removed")
        }
    }

    /// Stop seeding a torrent once it reaches `ratio` (nil = seed indefinitely).
    func setSeedRatioLimit(_ ratio: Double?, task id: DownloadTask.ID) {
        Task { await manager.setSeedRatioLimit(ratio, task: id) }
        if let ratio, ratio > 0 {
            toastNow(String(format: "Will stop seeding at ratio %.1f", ratio))
        } else {
            toastNow("Seeding indefinitely")
        }
    }

    /// Re-verify a torrent's downloaded data against its piece hashes.
    func forceRecheck(_ id: DownloadTask.ID) {
        Task { await manager.forceRecheck(id) }
        toastNow("Rechecking downloaded data…")
    }

    /// Force a torrent to re-announce to its trackers now.
    func forceReannounce(_ id: DownloadTask.ID) {
        Task { await manager.forceReannounce(id) }
        toastNow("Re-announcing to trackers…")
    }

    /// Assign or clear a category label for grouping downloads.
    func setLabel(_ label: String?, task id: DownloadTask.ID) {
        Task { await manager.setLabel(label, task: id) }
        toastNow(label.map { "Labelled “\($0)”" } ?? "Label removed")
    }

    /// The shared single-field text prompt: an `NSAlert` carrying one
    /// `NSTextField` accessory. Returns the entered string on confirm, `nil` on
    /// cancel — call sites layer their own trimming/validation on top.
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

    /// Prompt for a free-form category label with a native text field, prefilled
    /// with the current label. An empty value clears it.
    func promptForLabel(task: DownloadTask) {
        if let value = Self.promptText(
            title: "Label for “\(task.name)”",
            message: "Group this download under a category. Leave empty to remove.",
            confirm: "Save", initial: task.label ?? "",
            placeholder: "e.g. Movies, Linux ISOs", width: 240) {
            setLabel(value, task: task.id)
        }
    }

    // MARK: Rename

    /// Prompt for a new file name and rename the download (and its file on disk).
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

    /// Batch-rename the eligible selected downloads using a template. `#` is
    /// replaced with a running number (1, 2, …); the original extension is kept
    /// when the template has none.
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

    // MARK: Tags & notes

    /// Prompt for comma-separated tags, prefilled with the current set.
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

    /// Prompt for a free-form note with a multi-line field.
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

    // MARK: Referer & custom headers

    /// Prompt for a per-task `Referer` and extra request headers (HTTP downloads).
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

    // MARK: ffmpeg convert / extract audio

    /// Whether an ffmpeg binary is reachable (honouring the settings override).
    var ffmpegAvailable: Bool { FFmpegService.isAvailable(override: settings.ffmpegPath) }

    /// Convert a finished media file into another container next to the original.
    func convertFile(task: DownloadTask, toExtension ext: String) {
        let input = URL(fileURLWithPath: task.savePath)
        toastNow("Converting to \(ext.uppercased())…")
        Task {
            let outcome = await FFmpegService.convert(input: input, toExtension: ext,
                                                      override: settings.ffmpegPath)
            await MainActor.run { reportFFmpeg(outcome) }
        }
    }

    /// Extract the audio track of a finished media file next to the original.
    func extractAudio(task: DownloadTask, format: FFmpegService.AudioFormat) {
        let input = URL(fileURLWithPath: task.savePath)
        toastNow("Extracting \(format.rawValue.uppercased())…")
        Task {
            let outcome = await FFmpegService.extractAudio(input: input, format: format,
                                                           override: settings.ffmpegPath)
            await MainActor.run { reportFFmpeg(outcome) }
        }
    }

    private func reportFFmpeg(_ outcome: FFmpegService.Outcome) {
        switch outcome {
        case .success(let url): toastNow("Saved “\(url.lastPathComponent)”")
        case .failure(let msg): toastNow(msg)
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

    /// Localize a UI string key for the current language. Coverage is partial —
    /// unmapped keys fall back to English and then the key itself, so wrapping a
    /// literal is always safe even before its translation exists.
    func localized(_ key: String) -> String {
        L10n.string(key, language: settings.language)
    }
}
