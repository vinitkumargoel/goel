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
    /// App-side only: `TaskListQuery.Filter` has no failed case, so `ListPresentation` matches it itself.
    case failed
    /// Waiting for a slot. App-side like `failed`.
    case queued
    case type(FileType)
    /// Rows carrying this tag (or legacy label), compared case-insensitively.
    case tag(String)
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
    case eta = "ETA"
    case progress = "Progress"
    case remaining = "Remaining"
    case ratio = "Ratio"
    case peers = "Peers"
    var id: String { rawValue }
}

/// Three short tabs fit segmented in the 340 pt panel, where five collapsed into a pop-up menu.
/// Overview folds in General and Progress; Network folds in Details and Connections.
enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"
    case network = "Network"
    var id: String { rawValue }

    /// Files only earns a tab when there is a list to show: a torrent (even before its metadata
    /// arrives) or a multi-file download.
    static func available(for task: DownloadTask) -> [DetailTab] {
        task.kind == .torrent || task.files.count > 1 ? allCases : [.overview, .network]
    }

    /// The tab to draw for this task: a remembered Files tab falls back to Overview on a
    /// single-file download instead of showing an empty page.
    func resolved(for task: DownloadTask) -> DetailTab {
        Self.available(for: task).contains(self) ? self : .overview
    }
}

@MainActor
final class AppViewModel: ObservableObject {

    @Published var tasks: [DownloadTask] = [] { didSet { tasksRevision &+= 1 } }
    /// Bumped on every change to `tasks`, so derived values can be memoised against it.
    private(set) var tasksRevision = 0
    @Published private(set) var settings = AppSettings() {
        didSet {
            // Must land before the `@Published` change publishes, or the redraw reads the old language.
            if L10n.currentLanguage != settings.language {
                L10n.currentLanguage = settings.language
            }
            if settings.autoShutdown != oldValue.autoShutdown { refreshCommandState() }
            appearance.apply(settings)
        }
    }

    /// What the `App` scenes observe instead of this model.
    let appearance = AppAppearance()

    /// Memoized on purpose — as a computed property this re-sorts on every SwiftUI `body` pass.
    @Published private(set) var visibleTasks: [DownloadTask] = [] { didSet { visibleRevision &+= 1 } }
    /// Bumped on every change to `visibleTasks`; keys the `selectedTasks` memo.
    private(set) var visibleRevision = 0

    @Published var persistenceWarning: String?

    /// True until the first snapshot from disk lands, so the window shows placeholder rows
    /// instead of flashing the first-run screen over a queue that is still loading.
    @Published private(set) var isRestoring = true

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

    @Published var selection: Set<DownloadTask.ID> = [] {
        didSet {
            selectionRevision &+= 1
            refreshCommandState()
        }
    }
    /// Bumped on every change to `selection`; keys the `selectedTasks` memo.
    private(set) var selectionRevision = 0
    private var selectedTasksMemo: (visible: Int, selection: Int, value: [DownloadTask])?
    /// How many times `selectedTasks` was actually filtered; it also versions the selection
    /// summary, since it changes exactly when the selected rows do. Tests read it to prove reuse.
    private(set) var selectedTasksBuilds = 0

    @Published var primarySelection: DownloadTask.ID?

    /// Where a ⇧-click or ⇧-arrow measures its run from. Separate from `primarySelection`, which
    /// tracks the last row touched and drives the detail panel: a shift-extend has to move one
    /// without moving the other.
    @Published var selectionAnchor: DownloadTask.ID?

    /// Status, type and tag, ANDed. Narrowing drops hidden rows from the selection, so the
    /// detail panel never shows a download the list no longer does.
    @Published var filters = DownloadFilters() {
        didSet {
            guard filters != oldValue else { return }
            recomputeVisible()
            pruneSelectionToVisible()
        }
    }
    @Published var search: String = "" {
        didSet {
            recomputeVisible()
            pruneSelectionToVisible()
        }
    }
    @Published var sortKey: SortKey = .status { didSet { recomputeVisible() } }
    @Published var sortAscending: Bool = true { didSet { recomputeVisible() } }
    /// Remembered across launches: grouping is a way of working, not a momentary view.
    @Published var grouping: ListGrouping = AppViewModel.storedGrouping {
        didSet {
            UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey)
            recomputeVisible()
        }
    }
    /// `visibleTasks` split under the Group by headers; empty when not grouping.
    @Published private(set) var visibleSections: [ListSection] = []
    /// The board's lanes for `visibleTasks`, rebuilt with them rather than in every board body
    /// (which re-runs on each speed tick). Cards still read live speeds from `TelemetryStore`.
    @Published private(set) var boardLanes: [BoardLane] = []
    /// Each row's 1-based place in the queue — the "#" column and "Queued · #3".
    @Published private(set) var queueRanks: [DownloadTask.ID: Int] = [:]
    /// The rows a queue drag is carrying, set when the grip starts the drag. Drop targets read it
    /// because a drop's payload can only be read asynchronously, after the drop has been accepted.
    var queueDragIDs: [DownloadTask.ID] = []
    @Published var detailPanelVisible: Bool = true
    @Published var detailTab: DetailTab = .overview
    @Published var isAddSheetPresented: Bool = false
    @Published var isStatsPresented: Bool = false
    @Published var isHistoryPresented: Bool = false
    /// Bumped whenever the archived history changes; the History window reloads on it.
    @Published var historyRevision = 0
    @Published var isLinkGrabberPresented: Bool = false

    @Published var playerItem: PlayerItem?

    struct PlayerItem: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
    }

    @Published var servers: [SFTPConnection] = []

    /// Set when the saved-servers file exists but can't be read: an empty sidebar would
    /// otherwise look like "no servers" until the user tried to save one.
    @Published var serverStoreWarning: String?

    @Published var selectedServer: SFTPConnection.ID? { didSet { refreshCommandState() } }

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

    /// Lives in its own store: progress ticks must not redraw every view observing the model.
    let sftpStore = SFTPTransferStore()

    var sftpTransfers: [SFTPTransfer] {
        get { sftpStore.transfers }
        set { sftpStore.transfers = newValue }
    }

    @Published var sftpClipboard: SFTPClipboard?

    var sftpRemoteCopyPlans: [UUID: RemoteCopyPlan] = [:]

    @Published var sftpUploadConflicts: SFTPUploadConflictRequest?

    @Published var sftpMutationTick: Int = 0

    var sftpTransferTasks: [UUID: (task: Task<Void, Never>, cancel: CancelFlag)] = [:]

    /// IDs whose abort is a pause, not a cancel: the settle path keeps the row and its partial file.
    var sftpPauseIntents: Set<UUID> = []

    /// Per-file, not a running total: concurrent uploads complete out of order.
    var sftpFolderBytes: [UUID: [Int: Int64]] = [:]

    /// Speed read-outs and history rings; views that show numbers observe this directly.
    let telemetry = TelemetryStore()

    /// What the menu bar enables; the commands observe this, never the whole model.
    let commandState = CommandState()

    /// FIFO toasts, observed only by the overlays that draw them.
    let toasts = ToastQueue()

    /// Set by the main window so "Remove from List" lands on Edit ▸ Undo.
    weak var undoManager: UndoManager?

    /// Browser captures being handed to the manager right now; a second drain must skip them.
    var spoolFilesInFlight: Set<URL> = []

    /// Labels refresh at this rate; history rings take every other tick to hold their time span.
    private static let speedRefreshNanos: UInt64 = 500_000_000
    private static let speedPersistEveryTicks = 20
    private var speedSampleTick = 0
    private var speedSampler: Task<Void, Never>?
    private var lastPersistedSpeedHistory: [String: [SpeedHistoryPoint]] = [:]

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

    /// Set by the window while it is too narrow for a right-docked panel (see ``WindowLayout``).
    @Published var detailDockForcedBottom = false

    /// Where the panel is drawn: the preference, unless the window is too narrow for it.
    var effectiveDetailPanelPosition: DetailPanelPosition {
        detailDockForcedBottom ? .bottom : detailPanelPosition
    }

    /// Remembered across launches, like the grouping: hiding it is a way of working.
    @Published var sidebarVisible: Bool = UserDefaults.standard.object(forKey: AppViewModel.sidebarVisibleKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarVisibleKey) }
    }

    static let sidebarVisibleKey = "sidebarVisible"

    /// While set, the dialog covers the queue: selection commands (⌘P, ⌘⌫ …) stand down.
    @Published var confirmRequest: ConfirmRequest? { didSet { refreshCommandState() } }

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
    /// Where ``clipboardSuggestion`` came from, so the banner doesn't call a browser send a copied link.
    @Published var suggestionIsFromBrowser = false
    /// The suggestion is a video page for yt-dlp, not a file: accepting it opens the Add sheet's
    /// quality step instead of queueing the page's HTML.
    @Published var suggestionIsMediaPage = false
    /// Consumed by the Add sheet when it appears, or at once if it is already open; set for a page
    /// a browser sent, or a copied video page, for its video. Published so an open sheet sees it.
    @Published var addSheetPrefill: String?
    /// Consumed by the Add sheet: the palette's "Where is…" checksum/mirrors/cookies entries open
    /// the review step with Advanced options already expanded instead of at a dead end.
    var addSheetRevealsAdvanced = false

    let manager: DownloadManager
    private var updatesTask: Task<Void, Never>?
    /// Set synchronously on entry: `start()` suspends several times before `updatesTask` exists,
    /// and a second `.task` run in that window used to install every monitor twice.
    private var didStart = false
    private var externalAddObserver: NSObjectProtocol?
    private var lastWarningPoll = Date.distantPast

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
    private var hasConsumedFirstSnapshot = false

    private var reducerState = ReducerState()
    /// Completions within a few seconds share one summary banner.
    let completionBatcher = CompletionBannerBatcher()

    /// The one-minute grace before an automatic quit, sleep or shutdown.
    private(set) lazy var autoShutdownCountdown: AutoShutdownCountdown = {
        let countdown = AutoShutdownCountdown { [weak self] intent in self?.system.perform(intent) }
        countdown.onBegin = { intent in
            NotificationService.notifyAutoShutdown(
                title: AutoShutdownCountdown.title(for: intent),
                body: AutoShutdownCountdown.message(remaining: AutoShutdownCountdown.defaultSeconds))
            // The blocking card lives in the main window: bring one up so it can be seen and cancelled.
            MainWindowPresenter.activate()
        }
        countdown.onEnd = { NotificationService.retractAutoShutdown() }
        return countdown
    }()

    /// The database couldn't be opened; the banner offers to move it aside.
    @Published var databaseRecovery: DatabaseRecovery?

    struct DatabaseRecovery: Equatable {
        let path: String
        let reason: String
    }

    private let fileProgress = FileProgressPublisher()

    private let dockProgress = DockProgressService()

    private let system: SystemActions

    /// Weak: scripting must never keep a discarded view model alive.
    static private(set) weak var shared: AppViewModel?

    /// The seam behind the production init. The DEBUG snapshot harness passes an in-memory store
    /// and a manager with inert engines, so a model can be built without touching the user's
    /// database, Keychain or network; `start()` is what brings the engine up, and it never calls it.
    /// `settings` seeds the model as `start()` otherwise would from the manager.
    init(system: SystemActions, opened: OpenedStore, manager: DownloadManager, settings: AppSettings? = nil) {
        self.manager = manager
        self.persistenceWarning = opened.warning
        self.databaseRecovery = opened.recovery
        self.isStoreEphemeral = opened.isEphemeral
        self.system = system
        if let settings { self.settings = settings }
        Self.shared = self
    }

    struct OpenedStore {
        var store: PersistenceStore?
        var warning: String?
        var recovery: DatabaseRecovery?
        /// Nothing added this session survives a relaunch (a temporary store, or none at all).
        var isEphemeral: Bool { warning != nil }
    }

    /// The queue isn't being saved to disk: its banner can't be dismissed, so running without
    /// persistence is never silent.
    let isStoreEphemeral: Bool

    func start() async {
        guard !didStart else { return }
        didStart = true
        await manager.restore()
        if !isStoreEphemeral {
            let manager = self.manager
            Task.detached(priority: .utility) { await manager.sweepOrphanedSpool() }
        }
        // Subscribed straight after restore so the list paints before the monitors below come up.
        let stream = await manager.updates()
        settings = await manager.currentSettings
        ActiveWorkGate.shared.menuBarVisible = settings.menuBarExtraEnabled
        startConsuming(stream)
        syncMediaJobCenter()
        loadServersInBackground()
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
        // `queue: .main` delivers on the main thread, which is what `assumeIsolated` asserts.
        networkChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.system.config.network_change"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAggregationState() }
        }
        refreshAggregationState()
        startSpeedSampler()
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let manager = self.manager
                Task { await manager.reconcileCompletedFiles() }
                // A launch-only policy read would be dodged by never quitting the app.
                self.refreshManagedPolicy()
            }
        }
        appTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistSpeedHistory() }
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
        // Kept, so the observer can be removed; an anonymous token outlives nothing but leaks.
        externalAddObserver = NotificationCenter.default.addObserver(
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
    }

    /// Persistence warnings are rare; asking the actor on every 10 Hz snapshot was a wasted hop.
    private static let warningPollInterval: TimeInterval = 2

    private func startConsuming(_ stream: AsyncStream<[DownloadTask]>) {
        let manager = self.manager
        updatesTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.consume(snapshot)
                // Notices are posted with a publish, so the snapshot that follows is the moment to collect them.
                let notices = await manager.takeNotices()
                for notice in notices { self.toastNow(notice.message, isError: notice.isError) }
                let now = Date()
                if now.timeIntervalSince(self.lastWarningPoll) >= Self.warningPollInterval {
                    self.lastWarningPoll = now
                    if let warning = await manager.currentPersistenceWarning,
                       warning != self.persistenceWarning {
                        self.persistenceWarning = warning
                    }
                }
            }
        }
    }

    private func consume(_ snapshot: [DownloadTask]) {
        // Snapshots arrive only on change, so comparing the whole array first was pure cost.
        tasks = snapshot
        recomputeVisible()
        // Exactly once at launch, so "Select none" sticks instead of snapping back.
        if primarySelection == nil && !hasAutoSelected, let first = visibleTasks.first?.id {
            hasAutoSelected = true
            primarySelection = first
            selection = [first]
            selectionAnchor = first
        }
        if !hasConsumedFirstSnapshot {
            hasConsumedFirstSnapshot = true
            isRestoring = false
            installNotificationHandlers()
        }
        pump(snapshot)
        fileProgress.update(with: tasks) { [weak self] id in
            self?.pause(id)
        }
        refreshDockProgress()
    }

    func recomputeVisible() {
        let sorted = ListPresentation.visible(
            tasks: tasks,
            filters: filters,
            search: search,
            sortKey: sortKey,
            ascending: sortAscending
        )
        // Ungrouped, the list draws `visibleTasks` directly; building a section too would only
        // double the per-snapshot comparison below.
        let sections = grouping == .none ? [] : ListPresentation.sections(sorted, by: grouping)
        // Flattened from the sections, so arrow keys and ⇧-click ranges walk the rows as drawn.
        let next = grouping == .none ? sorted : sections.flatMap(\.tasks)
        // An unchanged list must not republish: every row body would re-run for nothing.
        if next != visibleTasks { visibleTasks = next }
        if sections != visibleSections { visibleSections = sections }
        let ranks = QueueOrder.ranks(tasks)
        if ranks != queueRanks { queueRanks = ranks }
        let lanes = BoardLanes.make(visible: next, sections: sections, grouping: grouping, ranks: ranks)
        if lanes != boardLanes { boardLanes = lanes }
        refreshCommandState()
    }

    func refreshCommandState() {
        commandState.apply(.make(tasks: tasks, visible: visibleTasks, selection: selection,
                                 listVisible: selectedServer == nil && confirmRequest == nil,
                                 autoShutdown: settings.autoShutdown))
    }


    /// One filter on its own across every task: the rail's counts and badges.
    func count(for filter: SidebarFilter) -> Int {
        ListPresentation.count(tasks: tasks, filter: filter)
    }

    /// How many rows picking `filter` would show with the other axes kept: the header chips.
    func facetCount(for filter: SidebarFilter) -> Int {
        ListPresentation.count(tasks: tasks, filters: filters.setting(filter))
    }

    /// Rows every active filter lets through, before the search: an active filter chip's count.
    var visibleCountIgnoringSearch: Int { ListPresentation.count(tasks: tasks, filters: filters) }

    /// The single-filter view of `filters`, for callers that pick one filter at a time (the
    /// rail, ⌘1…⌘9, the palette, the menu bar). Setting `.all` shows everything (every axis
    /// cleared); any other value changes only its own axis.
    var filter: SidebarFilter {
        get { filters.primary }
        set { filters = newValue == .all ? DownloadFilters() : filters.setting(newValue) }
    }

    func pruneSelectionToVisible() {
        let kept = SelectionRange.pruned(selection: selection, primary: primarySelection,
                                         anchor: selectionAnchor, visible: visibleTasks.map(\.id))
        if kept.selection != selection { selection = kept.selection }
        if kept.primary != primarySelection { primarySelection = kept.primary }
        if kept.anchor != selectionAnchor { selectionAnchor = kept.anchor }
    }

    var selectedTask: DownloadTask? {
        guard let primarySelection else { return nil }
        return tasks.first { $0.id == primarySelection }
    }

    /// The whole queue at the displayed speeds; shared, so the status bar and the board's queue
    /// card don't each fold every task on every speed tick.
    var queueOverview: QueueOverview { telemetry.queueOverview(for: tasks, revision: tasksRevision) }

    /// The selected rows in list order — what every command acting on "the selection" runs over.
    /// Filtered once per list or selection change rather than in every body on every speed tick.
    var selectedTasks: [DownloadTask] {
        if let memo = selectedTasksMemo, memo.visible == visibleRevision, memo.selection == selectionRevision {
            return memo.value
        }
        let value = visibleTasks.filter { selection.contains($0.id) }
        selectedTasksMemo = (visibleRevision, selectionRevision, value)
        selectedTasksBuilds &+= 1
        return value
    }

    /// The multi-selection panel's aggregate and overview, shared and refolded only when the
    /// selected rows or the displayed speeds change.
    var selectionSummary: SelectionSummary {
        let tasks = selectedTasks
        return telemetry.selectionSummary(for: tasks, revision: selectedTasksBuilds)
    }

    var totalDownloadSpeed: Double { tasks.reduce(0) { $0 + $1.downloadSpeed } }
    var totalUploadSpeed: Double { tasks.reduce(0) { $0 + $1.uploadSpeed } }

    var sftpUploadSpeed: Double {
        sftpTransfers.reduce(0) { $0 + ($1.isActive && $1.direction == .upload ? $1.displaySpeed : 0) }
    }
    var sftpDownloadSpeed: Double {
        sftpTransfers.reduce(0) { $0 + ($1.isActive && $1.direction == .download ? $1.displaySpeed : 0) }
    }

    var combinedDownloadSpeed: Double { totalDownloadSpeed + sftpDownloadSpeed }
    var combinedUploadSpeed: Double { totalUploadSpeed + sftpUploadSpeed }


    func add(rawLines: String, saveDirectory: String?, priority: FilePriority,
             expectedChecksum: Checksum? = nil) {
        var sources = InboundAdd.parseSources(from: rawLines)
        let metalinks = sources.filter(Self.isMetalink)
        sources.removeAll(where: Self.isMetalink)
        for case .url(let metalink) in metalinks {
            importMetalink(metalink, saveDirectory: saveDirectory, priority: priority)
        }
        guard !sources.isEmpty else {
            if metalinks.isEmpty { toastWarning(L10n.t("Enter a URL or magnet link first")) }
            return
        }
        let existingKeys = Set(tasks.map(\.source.dedupKey))
        var batchKeys = Set<String>()
        let fresh = sources.filter {
            batchKeys.insert($0.dedupKey).inserted && !existingKeys.contains($0.dedupKey)
        }
        let skipped = sources.count - fresh.count
        guard !fresh.isEmpty else {
            if sources.count == 1, let existing = tasks.first(where: { $0.source.dedupKey == sources[0].dedupKey }) {
                let id = existing.id
                toastWarning(L10n.t("Already in your list"),
                             action: Toast.Action(title: L10n.t("Show")) { [weak self] in self?.reveal(id) })
            } else {
                toastWarning(sources.count == 1 ? L10n.t("Already in your list")
                                                : L10n.t("All %d are already in your list", sources.count))
            }
            return
        }
        // Never apply one checksum to every download in a batch.
        let checksum = fresh.count == 1 ? expectedChecksum : nil
        let loginLines = InlineCredentials.linesWithLogins(in: rawLines)
        let manager = self.manager
        Task {
            // Before the adds: the engine looks the login up when the download starts.
            for line in loginLines { await manager.adoptInlineCredentials(line, replaceExisting: true) }
            for source in fresh {
                await manager.add(source: source, saveDirectory: saveDirectory,
                                  priority: priority, expectedChecksum: checksum)
            }
        }
        if skipped > 0 {
            toastSuccess(L10n.t("Added %1$@ · skipped %2$@ already in your list",
                            String(fresh.count), String(skipped)))
        } else {
            toastSuccess(fresh.count > 1 ? L10n.t("Added %d downloads to queue", fresh.count) : L10n.t("Added to queue"))
        }
        filter = .all
    }


    func existingDuplicate(of source: DownloadSource) -> DownloadTask? {
        tasks.first { $0.source.dedupKey == source.dedupKey }
    }

    static func isMetalink(_ source: DownloadSource) -> Bool {
        guard case .url(let url) = source else { return false }
        return ["metalink", "meta4"].contains(url.pathExtension.lowercased())
    }

    /// Metalinks are small XML files; anything bigger is refused before it's parsed.
    static let metalinkByteCap = 5_000_000

    private func importMetalink(_ url: URL, saveDirectory: String?, priority: FilePriority) {
        let proxy = Self.proxySpec(from: settings)
        let agent = Self.updateUserAgent(from: settings)
        Task { @MainActor in
            do {
                // Through NetworkGuard: the configured proxy and User-Agent, bounded redirects, no link-local.
                let data = try await NetworkGuard.fetchChecked(url: url, proxy: proxy, userAgent: agent)
                guard data.count <= Self.metalinkByteCap else {
                    toastNow(L10n.t("That metalink file is too large to be a download list"), isError: true)
                    return
                }
                let files = MetalinkParser.parse(data)
                guard !files.isEmpty else {
                    toastWarning(L10n.t("No downloads found in the metalink"))
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
                toastNow(added > 0 ? L10n.t("Added %d from metalink", added)
                                   : L10n.t("Metalink contents already in your list"),
                         kind: added > 0 ? .success : .warning)
                filter = .all
            } catch {
                toastNow(L10n.t("Couldn’t load the metalink file: %@", Self.fetchFailureMessage(error)),
                         isError: true)
            }
        }
    }

    func parsedSources(in rawLines: String) -> [DownloadSource] {
        InboundAdd.parseSources(from: rawLines)
    }

    func resolveMetadata(for line: String, saveDirectory: String?) async -> DownloadPreview? {
        // No login is saved here: the user may still cancel. ``confirm`` adopts it.
        guard let source = Self.parseSource(line) else { return nil }
        return await manager.resolveMetadata(for: source, saveDirectory: saveDirectory)
    }

    func confirm(_ preview: DownloadPreview, saveDirectory: String?,
                 priority: FilePriority, checksum: Checksum?, startAt: Date? = nil,
                 mirrors: [String]? = nil, deselectedFileIDs: [Int]? = nil,
                 cookieHeader: String? = nil, cookieSource: CookieSource? = nil,
                 cookieHost: String? = nil, inlineLoginLine: String? = nil,
                 name: String? = nil, whenDone: WhenDone? = nil,
                 onAdded: ((DownloadTask.ID) -> Void)? = nil) {
        if let duplicate = existingDuplicate(of: preview.source) {
            let id = duplicate.id
            toastWarning(L10n.t("Already in your list"),
                         action: Toast.Action(title: L10n.t("Show")) { [weak self] in self?.reveal(id) })
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
        // Only the line the user confirmed, and only now: the parsed preview carries no login.
        let loginLine = inlineLoginLine.flatMap { InlineCredentials.find(in: $0) == nil ? nil : $0 }
        if let saveDirectory { RecentFolders.remember(saveDirectory) }
        Task {
            // A plain-http login is refused with a notice from the manager; nil means it wasn't a link.
            if let loginLine, await manager.adoptInlineCredentials(loginLine, replaceExisting: true) == nil {
                toastNow(L10n.t("That link isn’t valid."), isError: true)
            }
            let added = await manager.add(source: source, saveDirectory: saveDirectory,
                              priority: priority, expectedChecksum: checksum,
                              scheduledAt: startAt, mirrors: mirrors,
                              suggestedName: name ?? preview.suggestedName,
                              totalBytes: seededBytes, files: seededFiles,
                              deselectedFileIDs: skipFiles,
                              cookieHeader: cookieHeader,
                              cookieSource: cookieSource,
                              cookieHost: cookieHost,
                              whenDone: whenDone)
            onAdded?(added.id)
            let show = Toast.Action(title: L10n.t("Show")) { [weak self] in self?.reveal(added.id) }
            if let startAt {
                let formatter = RelativeDateTimeFormatter()
                toastNow(L10n.t("Will start %@", formatter.localizedString(for: startAt, relativeTo: Date())),
                         action: show)
            } else {
                toastSuccess(L10n.t("Added “%@”", added.name), action: show)
            }
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
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var link = lines.first { Self.parseSource($0)?.looksLikeDownloadableFile == true }
        var isMediaPage = false
        if link == nil, YtDlpResolver.isAvailable,
           let page = lines.first(where: { URL(string: $0).map(MediaPageLink.isLikelyVideoPage) ?? false }) {
            link = page
            isMediaPage = true
        }
        guard let link, link != lastClipboardHandled, let source = Self.parseSource(link) else { return }
        if tasks.contains(where: { $0.source.dedupKey == source.dedupKey }) { return }
        lastClipboardHandled = link
        suggestionIsFromBrowser = false
        suggestionIsMediaPage = isMediaPage
        clipboardSuggestion = link
    }

    func acceptClipboardSuggestion() {
        guard let link = clipboardSuggestion else { return }
        clipboardSuggestion = nil
        if suggestionIsMediaPage {
            // Only the Add sheet runs yt-dlp; queueing the page itself would save its HTML.
            addSheetPrefill = link
            isAddSheetPresented = true
            return
        }
        add(rawLines: link, saveDirectory: nil, priority: .normal)
    }

    func dismissClipboardSuggestion() {
        clipboardSuggestion = nil
    }

    /// Web-triggerable `goeldownloader://` payloads must go through confirmation, never straight to the queue.
    private func handleExternalAdd(_ payload: ExternalAdd.Payload) {
        // Reopens the main window if it was closed: the scene no longer makes one per URL.
        MainWindowPresenter.activate()
        if payload.drainBrowserSpool {
            drainBrowserSpool()
            return
        }
        if let torrent = payload.torrentFile {
            Task { await manager.add(source: .torrentFile(torrent)) }
            toastSuccess(L10n.t("Added to queue"))
            return
        }
        guard let lines = payload.lines else { return }
        if payload.opensAddSheet, let first = parsedSources(in: lines).first {
            addSheetPrefill = first.locator
            isAddSheetPresented = true
            return
        }
        if payload.needsConfirmation {
            if let first = parsedSources(in: lines).first {
                suggestionIsFromBrowser = true
                suggestionIsMediaPage = false
                clipboardSuggestion = first.locator
            }
        } else {
            add(rawLines: lines, saveDirectory: nil, priority: .normal)
        }
    }

    /// No confirmation: only local processes can write the spool, and the host already validated it.
    /// Each file is deleted only after its download is in the queue (or it was refused on purpose).
    private func drainBrowserSpool() {
        let pending = BrowserSpool.pendingCaptures().filter { !spoolFilesInFlight.contains($0.file) }
        guard !pending.isEmpty else { return }
        let proxyResolves = NetworkGuard.usesRemoteDNS(Self.proxySpec(from: settings))
        let portalPort = settings.remoteAccessEnabled ? settings.remotePort : nil
        // One add per capture: batching would flatten distinct cookie scopes into one and leak them.
        for spooled in pending {
            let capture = spooled.capture
            // Re-validate the scheme: auto-add must never open an authenticated sftp:/ftp: connection.
            guard let source = DownloadSource.parse(capture.locator), source.isBrowserCaptureSafe else {
                BrowserSpool.reject(spooled.file, reason: "unsupported scheme")
                continue
            }
            spoolFilesInFlight.insert(spooled.file)
            Task {
                defer { spoolFilesInFlight.remove(spooled.file) }
                // Re-screen RESOLVED addresses (`localtest.me` is loopback behind DNS). Private LAN
                // targets pass: the user clicked this link in their own browser.
                if let target = source.fetchTargetURL {
                    let verdict = await BrowserCaptureScreen.verdict(target, portalPort: portalPort,
                                                                     resolvedByProxy: proxyResolves)
                    if case .refused(let why) = verdict {
                        toastNow(L10n.t("Refused a link from the browser — it points at this Mac’s own services or a link-local address"),
                                 isError: true)
                        BrowserSpool.reject(spooled.file, reason: why)
                        return
                    }
                }
                if let authorization = capture.authorization, let target = source.fetchTargetURL,
                   let line = InlineCredentials.line(for: target, authorization: authorization) {
                    // A page can put any userinfo in a link: it may add a login, never replace one.
                    await manager.adoptInlineCredentials(line, replaceExisting: false)
                }
                let task = await manager.add(source: source, priority: .normal,
                                             cookieHeader: capture.cookieHeader,
                                             cookieSource: capture.cookieHeader == nil ? CookieSource.none : .browser,
                                             cookieHost: capture.cookieHost)
                if let referer = capture.referer {
                    await manager.setRequestOptions(referer: referer, headers: nil, task: task.id)
                }
                BrowserSpool.acknowledge(spooled.file)
            }
        }
    }

    /// The core parser enforces the scheme allowlist — http/https/ftp/ftps/sftp/magnet, nothing else.
    static func parseSource(_ line: String) -> DownloadSource? {
        DownloadSource.parse(line)
    }

    /// Whatever the write pipeline still has buffered dies with the process, and the
    /// `willTerminate` observer fires *after* the drain — so the speed history is flushed
    /// here, where the terminate reply is still being held back, not from that observer.
    func shutdownCore() async {
        persistSpeedHistory()
        // Includes the engines' own shutdown (torrent resume data), bounded by the manager's deadline.
        await manager.shutdown()
    }

    func pause(_ id: DownloadTask.ID) { Task { await manager.pause(id) } }
    func resume(_ id: DownloadTask.ID) { Task { await manager.resume(id) } }
    func retry(_ id: DownloadTask.ID) {
        // Failed tasks need this path: resume() ignores anything not paused.
        Task { await manager.retry(id) }
    }

    /// Only claims success when there was something to act on.
    func pauseAll() {
        guard commandState.snapshot.hasPausable else { toastWarning(L10n.t("Nothing to pause")); return }
        Task { await manager.pauseAll() }
        toastSuccess(L10n.t("Paused all downloads"))
    }

    func resumeAll() {
        guard commandState.snapshot.hasResumable else { toastWarning(L10n.t("Nothing to resume")); return }
        Task { await manager.resumeAll() }
        toastSuccess(L10n.t("Resumed all downloads"))
    }

    func setProfile(_ name: String) {
        Task {
            settings = await manager.setProfile(name)
        }
    }

    func toggleSnail() {
        let newValue = !settings.speedLimitEnabled
        Task {
            settings = await manager.setSpeedLimitEnabled(newValue)
            toastSuccess(newValue ? L10n.t("Speed limit on · %@", settings.selectedProfileName)
                              : L10n.t("Speed limit off · Unlimited"))
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
        if launchChanged, !LoginItemService.setEnabled(copy.launchAtLogin) {
            revertLaunchAtLogin(afterFailedEnable: copy.launchAtLogin)
        }
        if notificationsNewlyWanted { NotificationService.requestAuthorization() }
        applyRemoteAccess()
        networkAdapters = AdapterDirectory.enumerate()
        aggregationInactiveReason = DownloadManager.aggregationSinglePathReason(
            settings: settings,
            vpnDefaultRoute: AdapterDirectory.hasActiveVPNInterface(),
            adapters: networkAdapters)
    }

    /// Written straight to the settings instead of through `update`: that would call
    /// `LoginItemService` a second time and two failures could ping-pong. The Settings scene shows
    /// alerts, not the main window's toasts.
    private func revertLaunchAtLogin(afterFailedEnable enabled: Bool) {
        let reverted = !enabled
        settings.launchAtLogin = reverted
        // Queued after `update`'s own apply, so this is the write that survives.
        Task { settings = await manager.apply { $0.launchAtLogin = reverted } }
        settingsMessage(
            L10n.t("Launch at Login"),
            enabled
            ? L10n.t("macOS wouldn’t register Goel° as a login item, so the setting has been turned back off. Login items can only be registered by an app in your Applications folder, and macOS rate-limits repeated attempts — move Goel° there, then try again.")
            : L10n.t("macOS wouldn’t remove Goel° from your login items, so the setting has been turned back on. Try again in a moment, or remove it in System Settings ▸ General ▸ Login Items."))
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
                self.toastSuccess(L10n.t("Up to date — version %@", current))
            case .notConfigured:
                self.toastWarning(L10n.t("Set an update feed URL in Settings → Backup & Updates first"))
            case let .failed(message):
                self.toastError(L10n.t("Update check failed: %@", message))
            }
        }
    }

    static func proxySpec(from settings: AppSettings) -> NetworkGuard.ProxySpec {
        NetworkGuard.ProxySpec(mode: settings.proxyMode, type: settings.proxyType,
                               host: settings.proxyHost, port: settings.proxyPort)
    }

    /// An empty User-Agent is not "no preference" — several hosts refuse it.
    static func updateUserAgent(from settings: AppSettings) -> String {
        let trimmed = settings.userAgent.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "GoelDownloader/1.0 (macOS)" : trimmed
    }

    private func offerUpdate(version: String, url: URL) {
        requestConfirm(
            title: L10n.t("Version %@ is available", version),
            message: L10n.t("You’re running %@. Open the release page to download the update?",
                             UpdateChecker.currentVersion),
            confirmTitle: L10n.t("Open Release Page")
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
    }

    func openFile(_ task: DownloadTask) {
        let url = URL(fileURLWithPath: task.primaryFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            reportMissingFile(task)
            return
        }
        // A refusal here is not "nothing happened": no installed app claims this file.
        if !NSWorkspace.shared.open(url) {
            toastNow(L10n.t("macOS couldn’t open “%@” — no app is set to handle this kind of file",
                            task.name), isError: true)
        }
    }

    /// Every file action fails the same way — the file moved, was deleted, or its disk went away.
    private func reportMissingFile(_ task: DownloadTask) {
        toastNow(L10n.t("“%@” isn’t there any more — it was moved, deleted, or is on a disconnected disk",
                        task.name), isError: true)
    }

    func playInApp(_ task: DownloadTask) {
        let url = URL(fileURLWithPath: task.primaryFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            reportMissingFile(task)
            return
        }
        // The menu hides this action for containers AVFoundation cannot open, so reaching the
        // fallback means a non-menu caller: hand the file on rather than open a player that
        // would show nothing.
        guard InAppPlayback.canPlay(url) else {
            let ext = url.pathExtension.uppercased()
            toastNow(L10n.t("The built-in player can’t open %@ — opening your default player", ext))
            openFile(task)
            return
        }
        playerItem = PlayerItem(url: url, title: task.name)
    }

    func revealInFinder(_ task: DownloadTask) {
        let url = URL(fileURLWithPath: task.savePath)
        // Finder silently ignores a selection that no longer exists, so claiming success would be a lie.
        guard FileManager.default.fileExists(atPath: url.path) else {
            reportMissingFile(task)
            return
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
        toastSuccess(L10n.t("Revealed in Finder"))
    }

    func copyToPasteboard(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
        toastSuccess(L10n.t("Copied to clipboard"))
    }

    private func pump(_ snapshot: [DownloadTask]) {
        let env = ReducerEnv(
            notify: NotifyPrefs(onAdded: settings.notifyOnAdded,
                                onCompleted: settings.notifyOnCompleted,
                                onFailed: settings.notifyOnFailed,
                                onlyWhenInactive: settings.notifyOnlyWhenInactive),
            isAppActive: NSApp.isActive,
            shutdown: settings.autoShutdown)
        let previous = reducerState
        let output = SnapshotReducer.reduce(previous, snapshot, env)
        reducerState = output.state
        refreshActiveWorkGate()
        if let intent = output.drainIntent {
            update { $0.autoShutdown = .none }   // one-shot: never fire twice
            // A minute's grace with Cancel; the action itself runs when the countdown ends.
            autoShutdownCountdown.begin(intent)
        } else if autoShutdownCountdown.isCounting, reducerState.lastHadActiveWork {
            // New work started during the countdown: the queue isn't finished after all.
            autoShutdownCountdown.cancel()
            toastNow(L10n.t("Automatic action cancelled — downloads started again"))
        }
        postNotifications(output.notifications, previous: previous, snapshot: snapshot)
        runWhenDoneActions(snapshot, previous: previous)
        if Self.hasNewlyCompleted(snapshot, previous: previous.lastStatuses) { bumpHistoryRevision(after: 1) }
    }

    /// Whether this snapshot finished something the last one hadn't: the History window reloads.
    nonisolated static func hasNewlyCompleted(_ snapshot: [DownloadTask],
                                              previous: [DownloadTask.ID: DownloadStatus]) -> Bool {
        snapshot.contains { $0.status == .completed && previous[$0.id] != .completed }
    }

    /// The history row is written by the persistence pipeline after the status flips, so a
    /// completion reloads a moment later rather than reading the table before the row lands.
    func bumpHistoryRevision(after seconds: Double = 0) {
        guard seconds > 0 else { historyRevision &+= 1; return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.historyRevision &+= 1
        }
    }

    /// Completion banners go out per task (Show in Finder / Open, one banner per download);
    /// the rest go through the generic path.
    private func postNotifications(_ notifications: [AppNotification], previous: ReducerState,
                                   snapshot: [DownloadTask]) {
        guard !notifications.isEmpty else { return }
        let sound = settings.notificationSound
        guard let notifier = system as? CompletionNotifying else {
            return system.post(notifications, sound: sound)
        }
        var finished = snapshot.filter {
            $0.status == .completed && previous.lastStatuses[$0.id] != .completed
        }
        var failed = snapshot.filter {
            if case .failed = $0.status { return previous.lastStatuses[$0.id] != $0.status }
            return false
        }
        var batch: [NotificationPlanning.Finished] = []
        var others: [AppNotification] = []
        for notification in notifications {
            if case .completed(let name) = notification,
               let index = finished.firstIndex(where: { $0.name == name }) {
                batch.append(.init(taskID: finished.remove(at: index).id, name: name))
            } else if case .failed(let name) = notification,
                      let index = failed.firstIndex(where: { $0.name == name }) {
                let task = failed.remove(at: index)
                notifier.postFailed(taskID: task.id, name: name,
                                    reason: NotificationPlanning.failureBody(for: task.status), sound: sound)
            } else {
                others.append(notification)
            }
        }
        postCompletionBanners(batch, notifier: notifier, sound: sound)
        if !others.isEmpty { system.post(others, sound: sound) }
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
        // Byte counts that arrived since the last tick are announced now, in one redraw.
        defer { sftpStore.flushProgress() }
        // Skip when fully idle, or the writes re-render the speed read-outs twice a second for nothing.
        let hasActive = tasks.contains { $0.status.isActive } || sftpTransfers.contains { $0.isActive }
        if !hasActive, telemetry.isAtRest { return }
        speedSampleTick &+= 1
        let recordHistory = speedSampleTick.isMultiple(of: 2)
        telemetry.sample(tasks: tasks,
                         combined: SpeedSample(down: combinedDownloadSpeed, up: combinedUploadSpeed),
                         recordHistory: recordHistory)
        // SFTP rows read their speed here too, at the same cadence as download rows.
        let now = Date()
        var nextTransfers = sftpTransfers
        var sftpChanged = false
        for index in nextTransfers.indices {
            let next = nextTransfers[index].isActive ? nextTransfers[index].liveSpeed(at: now) : 0
            if nextTransfers[index].sampledSpeed != next {
                nextTransfers[index].sampledSpeed = next
                sftpChanged = true
            }
            if next > nextTransfers[index].peakSpeed {
                nextTransfers[index].peakSpeed = next
                sftpChanged = true
            }
        }
        if sftpChanged { sftpTransfers = nextTransfers }
        if recordHistory { telemetry.recordSFTP(nextTransfers) }
        if speedSampleTick.isMultiple(of: Self.speedPersistEveryTicks) {
            persistSpeedHistory()
        }
    }

    private func persistSpeedHistory() {
        let out = telemetry.persistableHistory(for: tasks)
        guard out != lastPersistedSpeedHistory else { return }
        lastPersistedSpeedHistory = out
        let manager = self.manager
        Task { await manager.persistSpeedHistory(out) }
    }

    private func loadPersistedSpeedHistory(_ saved: [String: [SpeedHistoryPoint]]) {
        lastPersistedSpeedHistory = saved
        guard !saved.isEmpty else { return }
        telemetry.restoreTaskHistory(saved)
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

    func relocateHistoryEntry(_ entry: HistoryEntry, to path: String) {
        Task {
            await manager.relocateHistoryEntry(entry, to: path)
            bumpHistoryRevision(after: 0.3)
        }
    }

    func clearHistory() {
        Task {
            await manager.clearHistory()
            bumpHistoryRevision(after: 0.3)
        }
        toastSuccess(L10n.t("History cleared"))
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
            toastSuccess(L10n.t("History exported"))
        } catch {
            toastError(L10n.t("Export failed"))
        }
    }

    func setScheduledStart(_ date: Date?, task id: DownloadTask.ID) {
        Task { await manager.setScheduledStart(date, task: id) }
        if let date {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            toastNow(L10n.t("Will start %@", formatter.localizedString(for: date, relativeTo: Date())))
        } else {
            toastSuccess(L10n.t("Scheduled start cancelled"))
        }
    }

    func exportBackup(to url: URL) {
        Task {
            do {
                let data = try await manager.exportEnvelope()
                try data.write(to: url)
                toastSuccess(L10n.t("Backup exported"))
            } catch {
                toastError(L10n.t("Export failed"))
            }
        }
    }

    /// A backup file is untrusted input and adopting its settings cannot be undone — always confirm.
    func importBackup(from url: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            toastError(L10n.t("Import failed — couldn’t read that file"))
            return
        }
        guard let incoming = Self.backupSettings(in: data) else {
            toastError(L10n.t("Import failed — not a valid backup file"))
            return
        }
        requestConfirm(
            title: L10n.t("Import this backup?"),
            message: Self.importSummary(
                changes: Self.adoptableSettingChanges(from: incoming, current: settings)),
            confirmTitle: L10n.t("Import")
        ) { [weak self] in
            self?.adoptBackup(data)
        }
    }

    private func adoptBackup(_ data: Data) {
        Task {
            do {
                let added = try await manager.importEnvelope(data)
                settings = await manager.currentSettings
                toastNow(added > 0 ? (added == 1 ? L10n.t("Imported %d download", added)
                                                 : L10n.t("Imported %d downloads", added))
                                   : L10n.t("Nothing new to import"),
                         kind: added > 0 ? .success : .warning)
            } catch {
                toastError(L10n.t("Import failed — not a valid backup file"))
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
            head = L10n.t("Its settings match yours, so no setting changes.")
        case 1:
            head = L10n.t("It changes %1$d setting: %2$@.", 1, changes.joined(separator: ", "))
        case 2...3:
            head = L10n.t("It changes %1$d settings: %2$@.",
                          changes.count, changes.joined(separator: ", "))
        default:
            head = L10n.t("It changes %1$d settings, including %2$@.",
                          changes.count, changes.prefix(3).joined(separator: ", "))
        }
        return head + " " + L10n.t("Downloads it contains are added paused; ones already in your "
            + "list are skipped.\n\n"
            + "Security-sensitive settings are never taken from a backup: your proxy, the remote "
            + "portal’s access, credentials and trusted-header (SSO) sign-in, your save and watch "
            + "folders, RSS feeds, update feed, and any script or antivirus paths all stay as they are.")
    }

    func setSequential(_ sequential: Bool, task id: DownloadTask.ID) {
        Task { await manager.setSequential(sequential, task: id) }
        toastSuccess(sequential ? L10n.t("Sequential download on") : L10n.t("Sequential download off"))
    }

    func setTaskSpeedLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) {
        Task { await manager.setTaskSpeedLimit(bytesPerSec, task: id) }
        if let bytesPerSec, bytesPerSec > 0 {
            toastSuccess(L10n.t("Limited to %@ — applies on next start", Double(bytesPerSec).speedString))
        } else {
            toastSuccess(L10n.t("Per-download limit removed"))
        }
    }

    func setTaskUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) {
        Task { await manager.setTaskUploadLimit(bytesPerSec, task: id) }
        if let bytesPerSec, bytesPerSec > 0 {
            toastSuccess(L10n.t("Upload limited to %@", Double(bytesPerSec).speedString))
        } else {
            toastSuccess(L10n.t("Upload limit removed"))
        }
    }

    func setSeedRatioLimit(_ ratio: Double?, task id: DownloadTask.ID) {
        Task { await manager.setSeedRatioLimit(ratio, task: id) }
        if let ratio, ratio > 0 {
            toastSuccess(L10n.t("Will stop seeding at ratio %.1f", ratio))
        } else {
            toastSuccess(L10n.t("Seeding indefinitely"))
        }
    }

    func forceRecheck(_ id: DownloadTask.ID) {
        Task { await manager.forceRecheck(id) }
        toastNow(L10n.t("Rechecking downloaded data…"))
    }

    func forceReannounce(_ id: DownloadTask.ID) {
        Task { await manager.forceReannounce(id) }
        toastNow(L10n.t("Re-announcing to trackers…"))
    }

    func setLabel(_ label: String?, task id: DownloadTask.ID) {
        Task { await manager.setLabel(label, task: id) }
        toastSuccess(label.map { L10n.t("Labelled “%@”", $0) } ?? L10n.t("Label removed"))
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
        alert.addButton(withTitle: L10n.t("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func promptForLabel(task: DownloadTask) {
        if let value = Self.promptText(
            title: L10n.t("Label for “%@”", task.name),
            message: L10n.t("Group this download under a category. Leave empty to remove."),
            confirm: L10n.t("Save"), initial: task.label ?? "",
            placeholder: L10n.t("e.g. Movies, Linux ISOs"), width: 240) {
            setLabel(value, task: task.id)
        }
    }

    func promptForRename(task: DownloadTask) {
        guard let newName = Self.promptText(
            title: L10n.t("Rename “%@”", task.name),
            message: L10n.t("Renames the download and its file on disk."),
            confirm: L10n.t("Rename"), initial: task.name) else { return }
        Task {
            let result = await manager.rename(task.id, to: newName)
            await MainActor.run {
                switch result {
                case .renamed(let name): toastSuccess(L10n.t("Renamed to “%@”", name))
                case .unchanged: break
                case .notFound: toastWarning(L10n.t("That download no longer exists"))
                case .unsupported: toastWarning(L10n.t("Torrents can’t be renamed here"))
                case .active: toastWarning(L10n.t("Pause the download before renaming"))
                case .ioError(let msg): toastError(L10n.t("Couldn’t rename: %@", msg))
                }
            }
        }
    }

    func promptForBatchRename(tasks: [DownloadTask]) {
        let eligible = tasks.filter { $0.kind != .torrent && !$0.status.isActive }
        guard !eligible.isEmpty else { toastWarning(L10n.t("Nothing eligible to rename")); return }
        guard let raw = Self.promptText(
            title: L10n.t("Rename %d downloads", eligible.count),
            message: L10n.t("Use “#” for a running number. The original extension is kept if you omit one."),
            confirm: L10n.t("Rename All"), initial: L10n.t("File #"),
            placeholder: L10n.t("e.g. Episode #")) else { return }
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
            _ = await MainActor.run {
                if failed == 0 {
                    toastSuccess(renamed == 1 ? L10n.t("Renamed %d download", renamed)
                                          : L10n.t("Renamed %d downloads", renamed))
                } else {
                    toastWarning(L10n.t("Renamed %1$@, %2$@ couldn’t be renamed",
                                    String(renamed), String(failed)))
                }
            }
        }
    }

    func promptForTags(task: DownloadTask) {
        guard let value = Self.promptText(
            title: L10n.t("Tags for “%@”", task.name),
            message: L10n.t("Comma-separated. Leave empty to clear."),
            confirm: "Save", initial: task.allTags.joined(separator: ", "),
            placeholder: "e.g. work, urgent, linux") else { return }
        let tags = PromptParsing.tags(from: value)
        Task { await manager.setTags(tags, task: task.id) }
        toastSuccess(tags.isEmpty ? L10n.t("Tags cleared") : L10n.t("Tags updated"))
    }

    func promptForNote(task: DownloadTask) {
        let alert = NSAlert()
        alert.messageText = L10n.t("Note for “%@”", task.name)
        alert.informativeText = L10n.t("Attach a free-form note. Leave empty to remove.")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        let text = NSTextView(frame: scroll.bounds)
        text.string = task.note ?? ""
        text.isRichText = false
        text.font = .systemFont(ofSize: 12)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.t("Save"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await manager.setNote(text.string, task: task.id) }
        toastSuccess(text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.t("Note removed") : L10n.t("Note saved"))
    }

    func promptForRequestOptions(task: DownloadTask) {
        let alert = NSAlert()
        alert.messageText = L10n.t("Request options for “%@”", task.name)
        alert.informativeText = L10n.t("Sent only to the download’s own host. One header per line as “Name: value”.")
        let container = NSStackView(frame: NSRect(x: 0, y: 0, width: 340, height: 150))
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        let refererLabel = NSTextField(labelWithString: L10n.t("Referer"))
        let referer = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        referer.stringValue = task.referer ?? ""
        referer.placeholderString = "https://example.com/page"
        let headersLabel = NSTextField(labelWithString: L10n.t("Headers"))
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
        alert.addButton(withTitle: L10n.t("Save"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let headers = PromptParsing.requestHeaders(from: headersView.string)
        Task {
            let dropped = await manager.setRequestOptions(referer: referer.stringValue,
                                                          headers: headers, task: task.id)
            await MainActor.run {
                if dropped.isEmpty {
                    toastSuccess(L10n.t("Request options saved"))
                } else {
                    let list = dropped.joined(separator: ", ")
                    toastWarning(dropped.count == 1
                             ? L10n.t("Saved — ignored reserved header: %@", list)
                             : L10n.t("Saved — ignored reserved headers: %@", list))
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

    /// Computed, not `static let`: a cached string would keep the language it was first built in.
    static var managedFootnote: String { L10n.t("Managed by your organisation.") }

    func revealAuditLogFolder() {
        let manager = self.manager
        Task {
            guard let url = await manager.auditLogDirectory() else {
                _ = await MainActor.run { self.toastWarning(L10n.t("Audit log is off — nothing written yet")) }
                return
            }
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
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
            NotificationService.notify(title: L10n.t("Conversion failed"),
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

    /// Queued, never overwriting: see ``ToastQueue``.
    @discardableResult
    func toastNow(_ message: String, isError: Bool = false, action: Toast.Action? = nil) -> Toast.ID? {
        toasts.show(message, isError: isError, action: action)
    }
}

#if DEBUG
extension AppViewModel {
    /// Snapshot harness only (see `UI/Snapshots/SampleData.swift`): shows `snapshot` as if the
    /// engine had published it, without the side effects of the live path — no notification
    /// handlers, no Dock progress, no Finder progress on files, no completion banners.
    func installSampleSnapshot(_ snapshot: [DownloadTask], selecting selected: DownloadTask.ID?) {
        tasks = snapshot
        recomputeVisible()
        hasAutoSelected = true
        hasConsumedFirstSnapshot = true
        isRestoring = false
        if let selected {
            primarySelection = selected
            selection = [selected]
            selectionAnchor = selected
        }
    }
}
#endif
