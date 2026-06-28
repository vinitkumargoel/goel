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

    @Published var selection: DownloadTask.ID?
    @Published var filter: SidebarFilter = .all { didSet { recomputeVisible() } }
    @Published var search: String = "" { didSet { recomputeVisible() } }
    @Published var sortKey: SortKey = .status { didSet { recomputeVisible() } }
    @Published var sortAscending: Bool = true { didSet { recomputeVisible() } }
    @Published var detailPanelVisible: Bool = true
    @Published var detailTab: DetailTab = .general
    @Published var isAddSheetPresented: Bool = false
    @Published var theme: AppTheme = .system

    /// A transient banner shown after notable actions (mirrors the demo toasts).
    @Published var toast: String?

    // MARK: Core

    private let manager: DownloadManager
    private var updatesTask: Task<Void, Never>?

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
                    if self.selection == nil { self.selection = snapshot.first?.id }
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
        guard let selection else { return nil }
        return tasks.first { $0.id == selection }
    }

    // MARK: Aggregate stats (status bar)

    var totalDownloadSpeed: Double { tasks.reduce(0) { $0 + $1.downloadSpeed } }
    var totalUploadSpeed: Double { tasks.reduce(0) { $0 + $1.uploadSpeed } }

    var preferredColorScheme: ColorScheme? { theme.colorScheme }

    // MARK: Actions — all bridge to the actor

    func add(rawLines: String, saveDirectory: String?, priority: FilePriority) {
        let lines = rawLines
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let sources = lines.compactMap(Self.parseSource)
        guard !sources.isEmpty else {
            toastNow("Enter a URL or magnet link first")
            return
        }
        Task {
            for source in sources {
                await manager.add(source: source, saveDirectory: saveDirectory, priority: priority)
            }
        }
        toastNow(sources.count > 1 ? "Added \(sources.count) downloads to queue" : "Added to queue")
        filter = .all
    }

    /// Delegates to the core parser, which enforces the scheme allowlist
    /// (http/https/magnet/.torrent only).
    static func parseSource(_ line: String) -> DownloadSource? {
        DownloadSource.parse(line)
    }

    func pause(_ id: DownloadTask.ID) { Task { await manager.pause(id) } }
    func resume(_ id: DownloadTask.ID) { Task { await manager.resume(id) } }
    func remove(_ id: DownloadTask.ID, deleteData: Bool) {
        Task { await manager.remove(id, deleteData: deleteData) }
        if selection == id { selection = nil }
    }
    func retry(_ id: DownloadTask.ID) {
        // Failed tasks need the dedicated retry path; resume() ignores non-paused.
        Task { await manager.retry(id) }
    }

    func pauseAll() { Task { await manager.pauseAll() } }
    func resumeAll() { Task { await manager.resumeAll() } }

    func setProfile(_ name: String) {
        Task {
            await manager.setProfile(name)
            settings = await manager.currentSettings
        }
    }

    func toggleSnail() {
        let newValue = !settings.speedLimitEnabled
        Task {
            await manager.setSpeedLimitEnabled(newValue)
            settings = await manager.currentSettings
            // Toast after the refresh so it reflects the committed settings.
            toastNow(newValue ? "Speed limit on · \(settings.selectedProfileName)" : "Speed limit off · Unlimited")
        }
    }

    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) {
        Task { await manager.setFilePriority(priority, fileID: fileID, task: id) }
    }

    func setDefaultSaveDirectory(_ path: String) {
        Task {
            await manager.setDefaultSaveDirectory(path)
            settings = await manager.currentSettings
        }
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

    private func toastNow(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toast == message { toast = nil }
        }
    }
}
