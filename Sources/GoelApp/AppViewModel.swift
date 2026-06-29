import Foundation
import SwiftUI
import Combine
import AppKit
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
    @Published private(set) var settings = AppSettings()

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

    /// Light / Dark / System, derived from (and persisted through) the core
    /// ``AppSettings/theme`` string so the choice survives relaunch. The setter
    /// commits via ``update(_:)`` like every other persisted preference.
    var theme: AppTheme {
        get { AppTheme(settingsValue: settings.theme) }
        set { update { $0.theme = newValue.settingsValue } }
    }

    /// A transient banner shown after notable actions (mirrors the demo toasts).
    @Published var toast: String?

    /// A copied link the clipboard monitor is offering to download, shown as an
    /// actionable banner. `nil` when there is nothing to suggest.
    @Published var clipboardSuggestion: String?

    // MARK: Core

    private let manager: DownloadManager
    private var updatesTask: Task<Void, Never>?

    /// Watches the pasteboard for copied download links (Tier-1 convenience).
    private var clipboardMonitor: ClipboardMonitor?

    /// The last link the clipboard monitor surfaced, so the same copy isn't
    /// offered twice (and a dismissed suggestion stays dismissed).
    private var lastClipboardHandled: String?

    /// Whether the one-time launch auto-select has already run. Once it has,
    /// clearing the selection ("Select none") sticks instead of snapping back to
    /// the first row on the next snapshot.
    private var hasAutoSelected = false

    /// Per-task status from the previous snapshot, used to detect added/completed/
    /// failed transitions for notifications. Seeded (not notified) on the first
    /// snapshot so restored tasks don't fire "added" banners at launch.
    private var lastStatuses: [DownloadTask.ID: DownloadStatus] = [:]
    private var hasSeenFirstSnapshot = false

    init() {
        // File-backed persistence under Application Support, falling back to an
        // ephemeral in-memory store if the directory can't be created — and
        // surfacing a warning when it does, rather than silently losing state.
        let (store, warning) = Self.makeStore()
        self.manager = DownloadManager(store: store)
        self.persistenceWarning = warning
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
                    self.emitNotifications(for: snapshot)
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
        let lines = rawLines
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let sources = lines.compactMap(Self.parseSource)
        guard !sources.isEmpty else {
            toastNow("Enter a URL or magnet link first")
            return
        }
        // A checksum only makes sense for a single file — never apply one supplied
        // alongside a multi-line batch to every download.
        let checksum = sources.count == 1 ? expectedChecksum : nil
        Task {
            for source in sources {
                await manager.add(source: source, saveDirectory: saveDirectory,
                                  priority: priority, expectedChecksum: checksum)
            }
        }
        toastNow(sources.count > 1 ? "Added \(sources.count) downloads to queue" : "Added to queue")
        filter = .all
    }

    // MARK: Two-step add (resolve metadata, then confirm)

    /// The parseable source locators in `rawLines`, in order. Used to decide
    /// between the single-item confirm flow and a multi-item batch add.
    func parsedSources(in rawLines: String) -> [DownloadSource] {
        rawLines
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap(Self.parseSource)
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
                 priority: FilePriority, checksum: Checksum?) {
        // A checksum only applies to a single-file HTTP/HLS download.
        let checksum = preview.kind == .torrent ? nil : checksum
        let source = preview.source
        Task {
            await manager.add(source: source, saveDirectory: saveDirectory,
                              priority: priority, expectedChecksum: checksum)
        }
        toastNow("Added to queue")
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
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
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

    // MARK: Notifications

    /// Diff this snapshot against the previous one and post a user notification for
    /// each added/completed/failed transition, gated by the matching `notify*`
    /// preference and ``AppSettings/notifyOnlyWhenInactive`` (which suppresses
    /// banners while the app is frontmost). The first snapshot only seeds the
    /// baseline so restored tasks never fire "added" banners at launch.
    private func emitNotifications(for snapshot: [DownloadTask]) {
        defer {
            lastStatuses = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.status) })
        }
        guard hasSeenFirstSnapshot else {
            hasSeenFirstSnapshot = true
            return
        }
        if settings.notifyOnlyWhenInactive && NSApp.isActive { return }
        let sound = settings.notificationSound
        for task in snapshot {
            guard let previous = lastStatuses[task.id] else {
                if settings.notifyOnAdded {
                    NotificationService.notify(title: "Download added", body: task.name, sound: sound)
                }
                continue
            }
            guard previous != task.status else { continue }
            switch task.status {
            case .completed:
                if settings.notifyOnCompleted {
                    NotificationService.notify(title: "Download complete", body: task.name, sound: sound)
                }
            case .failed:
                if settings.notifyOnFailed {
                    NotificationService.notify(title: "Download failed", body: task.name, sound: sound)
                }
            default:
                break
            }
        }
    }

    private func toastNow(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toast == message { toast = nil }
        }
    }
}
