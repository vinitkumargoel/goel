import Foundation
import SwiftUI
import Combine
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

    // MARK: Speed history (sparklines)

    /// One second of aggregate throughput.
    struct SpeedSample: Equatable {
        var down: Double
        var up: Double
    }

    /// The last ~2 minutes of global throughput, sampled at 1 Hz.
    @Published private(set) var globalSpeedHistory: [SpeedSample] = []

    /// Per-task history for the detail panel's sparkline (active tasks only).
    private(set) var taskSpeedHistory: [DownloadTask.ID: [SpeedSample]] = [:]

    private static let speedHistoryCap = 120
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
        netMonitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { await core.applyNetworkPolicy(expensive: expensive, constrained: constrained) }
        }
        netMonitor.start(queue: DispatchQueue(label: "goel.network-path"))
        pathMonitor = netMonitor
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
                        self.hasAutoSelected = true
                        if let first = self.visibleTasks.first?.id {
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
            list = list.filter { $0.name.lowercased().contains(q) }
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
        Task {
            await manager.add(source: source, saveDirectory: saveDirectory,
                              priority: priority, expectedChecksum: checksum,
                              scheduledAt: startAt, mirrors: mirrors,
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
        // Move the primary to the adjacent visible row *before* the snapshot drops
        // the deleted task, so selection lands on a neighbour that's actually in
        // the filtered list rather than jumping to the raw-first task.
        let nextPrimary = visibleNeighbor(after: id)
        Task { await manager.remove(id, deleteData: deleteData) }
        selection.remove(id)
        if primarySelection == id { primarySelection = nextPrimary }
    }
    func retry(_ id: DownloadTask.ID) {
        // Failed tasks need the dedicated retry path; resume() ignores non-paused.
        Task { await manager.retry(id) }
    }

    func pauseAll() { Task { await manager.pauseAll() } }
    func resumeAll() { Task { await manager.resumeAll() } }

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
        }
        if launchChanged { LoginItemService.setEnabled(copy.launchAtLogin) }
        if notificationsNewlyWanted { NotificationService.requestAuthorization() }
        applyRemoteAccess()
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
        var target = task.savePath
        if task.isMultiFile,
           let largest = task.files.filter(\.isWanted).max(by: { $0.length < $1.length }) {
            target = (task.saveDirectory as NSString).appendingPathComponent(largest.path)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: target))
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

    /// Sample aggregate and per-task throughput once a second for the
    /// sparklines. Runs for the app's lifetime; the ring caps keep memory flat.
    private func startSpeedSampler() {
        guard speedSampler == nil else { return }
        speedSampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.takeSpeedSample()
            }
        }
    }

    private func takeSpeedSample() {
        // Fully idle (no active task and a flat history): skip the sample so
        // the @Published append doesn't re-render the whole app every second
        // while it sits in the menu bar doing nothing.
        let hasActive = tasks.contains { $0.status.isActive }
        if !hasActive, globalSpeedHistory.allSatisfy({ $0 == SpeedSample(down: 0, up: 0) }) {
            return
        }
        var sample = SpeedSample(down: 0, up: 0)
        for task in tasks {
            sample.down += task.downloadSpeed
            sample.up += task.uploadSpeed
            guard task.status.isActive else { continue }
            var history = taskSpeedHistory[task.id] ?? []
            history.append(SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed))
            if history.count > Self.speedHistoryCap { history.removeFirst() }
            taskSpeedHistory[task.id] = history
        }
        // Drop history for tasks that no longer exist (kept for paused ones so
        // a brief pause doesn't wipe the graph).
        let known = Set(tasks.map(\.id))
        taskSpeedHistory = taskSpeedHistory.filter { known.contains($0.key) }
        globalSpeedHistory.append(sample)
        if globalSpeedHistory.count > Self.speedHistoryCap { globalSpeedHistory.removeFirst() }
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

    /// Prompt for a free-form category label with a native text field, prefilled
    /// with the current label. An empty value clears it.
    func promptForLabel(task: DownloadTask) {
        let alert = NSAlert()
        alert.messageText = "Label for “\(task.name)”"
        alert.informativeText = "Group this download under a category. Leave empty to remove."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = task.label ?? ""
        field.placeholderString = "e.g. Movies, Linux ISOs"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            setLabel(field.stringValue, task: task.id)
        }
    }

    func toastNow(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toast == message { toast = nil }
        }
    }
}
