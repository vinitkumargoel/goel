import Foundation

/// The scheduler — the single brain that owns the unified download queue.
///
/// It keeps one ordered list of ``DownloadTask``, routes each task to the right
/// engine by `source.kind` (HTTP vs torrent), subscribes to every engine's
/// `events(for:)` stream and folds those events back into the stored task, then
/// republishes immutable snapshots so a UI can observe. It also enforces the
/// active ``TrafficProfile``: no more than `maxSimultaneousDownloads` tasks
/// download at once (the rest sit `.queued` and are promoted, in priority order,
/// as slots free up), capped concurrent magnet-metadata resolutions, and the
/// bandwidth/connection limits pushed down to both engines via `applyLimits`.
///
/// It is an `actor`, so all queue bookkeeping is serialized and it is `Sendable`
/// for free. Engines are themselves actors, hence the `await`s. No UI framework
/// is imported — the manager is pure model logic.
public actor DownloadManager {

    // MARK: Engines

    private let httpEngine: any DownloadEngine
    private let torrentEngine: any DownloadEngine

    // MARK: State

    /// The unified, ordered task list. The single source of truth.
    private var tasks: [DownloadTask] = []

    /// User configuration (active profile, snail flag, default folder).
    private var settings: AppSettings

    /// Optional on-disk store. When present, the queue and settings survive quit
    /// & relaunch. Writes are dispatched off the actor so disk I/O never blocks
    /// queue bookkeeping (and never the main actor).
    private let store: PersistenceStore?

    /// Tasks currently occupying a download slot — i.e. handed to an engine and
    /// still in an active download phase (`.requestingMetadata` / `.downloading`).
    /// A task leaves this set the moment it pauses, fails, completes, or starts
    /// seeding, which is when a queued task may be promoted.
    private var runningSlots: Set<UUID> = []

    /// Tasks that have been `add`-ed to their engine at least once. Distinguishes
    /// a fresh start (`engine.add`) from a resume (`engine.resume`).
    private var engineStarted: Set<UUID> = []

    /// Per-task event-stream consumers.
    private var consumers: [UUID: Task<Void, Never>] = [:]

    /// Snapshot observers.
    private var observers: [UUID: AsyncStream<[DownloadTask]>.Continuation] = [:]

    // MARK: Init

    /// Inject the two engines (typed as `any DownloadEngine` so a real
    /// libtorrent shim can replace the mock without touching the scheduler).
    public init(
        httpEngine: any DownloadEngine,
        torrentEngine: any DownloadEngine,
        settings: AppSettings = AppSettings(),
        store: PersistenceStore? = nil
    ) {
        self.httpEngine = httpEngine
        self.torrentEngine = torrentEngine
        self.settings = settings
        self.store = store
    }

    /// Convenience initialiser wiring the production ``HTTPEngine`` and the
    /// ``MockTorrentEngine``.
    public init(settings: AppSettings = AppSettings(), store: PersistenceStore? = nil) {
        self.httpEngine = HTTPEngine(profile: settings.effectiveProfile)
        self.torrentEngine = MockTorrentEngine(profile: settings.effectiveProfile)
        self.settings = settings
        self.store = store
    }

    // MARK: Persistence

    /// Restore the queue and settings from the on-disk ``store`` (if any).
    ///
    /// Call this once, right after construction, before adding new downloads.
    /// Persisted settings replace the in-memory ones; persisted tasks are loaded
    /// with their `bytesDownloaded`/`resumeData`/error/seeding state intact.
    /// Tasks that were mid-flight (downloading / requesting metadata / queued)
    /// come back `.paused` so the user explicitly resumes them; terminal and
    /// already-paused tasks keep their state. No engine work is started here.
    public func restore() async {
        guard let store else { return }

        do {
            if let saved = try store.loadSettings() { settings = saved }
        } catch {
            notePersistenceError(error)
        }

        let loaded: [DownloadTask]
        do {
            loaded = try store.loadAllTasks()
        } catch {
            // Surface the failure instead of silently presenting an empty queue
            // (which is indistinguishable from a fresh install).
            persistenceWarning = "Couldn’t restore your downloads — the saved database may be unreadable."
            FileHandle.standardError.write(Data("[GoelDownloader] restore failed: \(error)\n".utf8))
            publish()
            return
        }

        tasks = loaded.map { task in
            var t = task
            switch t.status {
            case .downloading, .requestingMetadata, .queued:
                t.status = .paused
            default:
                break   // paused / seeding / completed / failed are preserved
            }
            t.downloadSpeed = 0
            t.uploadSpeed = 0
            t.connectionCount = 0
            return t
        }

        // Reflect any status normalisation back to disk.
        for task in tasks { persist(task) }
        await applyLimits()
        publish()
    }

    /// A human-readable persistence problem, surfaced to the UI (a failed disk
    /// write means the queue silently diverges from disk — the user must know).
    private var persistenceWarning: String?

    /// The latest persistence warning, if any. Polled by the UI bridge.
    public var currentPersistenceWarning: String? { persistenceWarning }

    /// Record (and log) a persistence failure so it can be surfaced.
    private func notePersistenceError(_ error: Error) {
        persistenceWarning = "Couldn’t save to disk: \(error.localizedDescription)"
        FileHandle.standardError.write(Data("[GoelDownloader] persistence error: \(error)\n".utf8))
    }

    /// Persist a single task off-actor. A failed write is captured and surfaced
    /// via ``currentPersistenceWarning`` rather than silently dropped, but it
    /// never stalls the queue.
    private func persist(_ task: DownloadTask) {
        guard let store else { return }
        Task.detached { [weak self] in
            do { try store.saveTask(task) }
            catch { await self?.notePersistenceError(error) }
        }
    }

    /// Persist the current settings off-actor.
    private func persistSettings() {
        guard let store else { return }
        let snapshot = settings
        Task.detached { [weak self] in
            do { try store.saveSettings(snapshot) }
            catch { await self?.notePersistenceError(error) }
        }
    }

    /// Remove a persisted task off-actor.
    private func persistRemoval(_ id: DownloadTask.ID) {
        guard let store else { return }
        Task.detached { [weak self] in
            do { try store.deleteTask(id) }
            catch { await self?.notePersistenceError(error) }
        }
    }

    // MARK: Observation

    /// The current task list.
    public var snapshot: [DownloadTask] { tasks }

    /// The current settings.
    public var currentSettings: AppSettings { settings }

    /// Look up a single task by id.
    public func task(_ id: DownloadTask.ID) -> DownloadTask? {
        tasks.first { $0.id == id }
    }

    /// A live stream of task-list snapshots. The current list is delivered
    /// immediately on subscription, then again after every change.
    public func updates() -> AsyncStream<[DownloadTask]> {
        let (stream, continuation) = AsyncStream<[DownloadTask]>.makeStream(bufferingPolicy: .unbounded)
        let key = UUID()
        observers[key] = continuation
        continuation.yield(tasks)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(key) }
        }
        return stream
    }

    private func removeObserver(_ key: UUID) {
        observers[key] = nil
    }

    private func publish() {
        let snapshot = tasks
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    /// Throttle progress-driven snapshots to ~10 Hz. Structural/status changes
    /// always publish immediately (via ``publish()``); only the high-frequency
    /// `.progress`/`.fileProgress` stream is coalesced, so the UI isn't flooded
    /// with whole-list snapshots dozens of times a second per task.
    private var lastProgressPublish = Date.distantPast
    private func throttledPublish() {
        let now = Date()
        if now.timeIntervalSince(lastProgressPublish) >= 0.1 {
            lastProgressPublish = now
            publish()
        }
    }

    // MARK: Public actions

    /// Add a download. If a task with the same `source.locator` already exists it
    /// is **not** duplicated — the existing task is returned instead. The new
    /// task starts `.queued`; the scheduler promotes it when a slot is free.
    @discardableResult
    public func add(
        source: DownloadSource,
        saveDirectory: String? = nil,
        priority: FilePriority = .normal
    ) -> DownloadTask {
        if let existing = tasks.first(where: { $0.source.locator == source.locator }) {
            return existing
        }
        let task = DownloadTask(
            source: source,
            name: Self.defaultName(for: source),
            saveDirectory: saveDirectory ?? settings.defaultSaveDirectory,
            status: .queued,
            priority: priority
        )
        tasks.append(task)
        persist(task)
        publish()
        schedule()
        return task
    }

    /// Add several sources at once. Duplicates resolve to the existing task.
    @discardableResult
    public func addBatch(
        sources: [DownloadSource],
        saveDirectory: String? = nil
    ) -> [DownloadTask] {
        sources.map { add(source: $0, saveDirectory: saveDirectory) }
    }

    /// Pause a task (queued or active). Frees its slot so a queued task can run.
    public func pause(_ id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        guard task.status != .paused, !task.status.isTerminal else { return }

        if engineStarted.contains(id) {
            await engine(for: task.source).pause(id)
        }
        runningSlots.remove(id)
        // Re-validate after the await: the task may have completed or failed while
        // the actor was suspended — never clobber a terminal state with `.paused`.
        guard let i = index(of: id), !tasks[i].status.isTerminal else {
            publish()
            schedule()
            return
        }
        tasks[i].status = .paused
        tasks[i].downloadSpeed = 0
        tasks[i].uploadSpeed = 0
        persist(tasks[i])
        publish()
        schedule()
    }

    /// Resume a paused task. It re-enters the queue and is promoted subject to
    /// the simultaneous-download cap.
    public func resume(_ id: DownloadTask.ID) async {
        guard let i = index(of: id), tasks[i].status == .paused else { return }
        tasks[i].status = .queued
        persist(tasks[i])
        publish()
        schedule()
    }

    /// Retry a failed task: clear the error and re-queue it (keeping any partial
    /// bytes / resume cursor so it can continue), then let the scheduler promote
    /// it. A no-op unless the task is currently `.failed`.
    public func retry(_ id: DownloadTask.ID) async {
        guard let i = index(of: id), case .failed = tasks[i].status else { return }
        tasks[i].status = .queued
        tasks[i].downloadSpeed = 0
        tasks[i].uploadSpeed = 0
        persist(tasks[i])
        publish()
        schedule()
    }

    /// Remove a task entirely, optionally deleting its data from disk.
    public func remove(_ id: DownloadTask.ID, deleteData: Bool) async {
        guard let task = task(id) else { return }
        if engineStarted.contains(id) {
            await engine(for: task.source).remove(id, deleteData: deleteData)
        }
        consumers[id]?.cancel()
        consumers[id] = nil
        runningSlots.remove(id)
        engineStarted.remove(id)
        if let i = index(of: id) { tasks.remove(at: i) }
        persistRemoval(id)
        publish()
        schedule()
    }

    /// Tear down all live subscriptions and observers. Call before releasing the
    /// manager so no consumer Tasks or stream continuations are left dangling.
    public func shutdown() {
        for consumer in consumers.values { consumer.cancel() }
        consumers.removeAll()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    /// Pause every queued or active task.
    public func pauseAll() async {
        let ids = tasks
            .filter { $0.status.isActive || $0.status == .queued }
            .map(\.id)
        for id in ids { await pause(id) }
    }

    /// Resume every paused task.
    public func resumeAll() async {
        let ids = tasks.filter { $0.status == .paused }.map(\.id)
        for id in ids { await resume(id) }
    }

    /// Switch the active traffic profile. Re-applies limits to both engines live
    /// and re-runs the scheduler (the simultaneous cap may have changed).
    public func setProfile(_ name: String) async {
        settings.selectedProfileName = name
        persistSettings()
        await applyLimits()
        publish()
        schedule()
    }

    /// Toggle the "snail" speed limit. When disabled, speeds become unlimited.
    /// Re-applies limits to both engines live.
    public func setSpeedLimitEnabled(_ enabled: Bool) async {
        settings.speedLimitEnabled = enabled
        persistSettings()
        await applyLimits()
        publish()
    }

    /// Change the default save folder for future downloads.
    public func setDefaultSaveDirectory(_ path: String) {
        settings.defaultSaveDirectory = path
        persistSettings()
        publish()
    }

    /// Change a file's selection / priority within a (multi-file) task.
    public func setFilePriority(
        _ priority: FilePriority,
        fileID: Int,
        task id: DownloadTask.ID
    ) async {
        guard let task = task(id) else { return }
        await engine(for: task.source).setFilePriority(priority, fileID: fileID, task: id)
        if let i = index(of: id),
           let f = tasks[i].files.firstIndex(where: { $0.id == fileID }) {
            tasks[i].files[f].priority = priority
            persist(tasks[i])
        }
        publish()
    }

    /// Push the current effective profile to both engines. Useful at startup.
    public func applyLimits() async {
        let profile = settings.effectiveProfile
        await httpEngine.applyLimits(profile)
        await torrentEngine.applyLimits(profile)
    }

    // MARK: Scheduling

    /// Promote queued tasks into free download slots, honouring the simultaneous
    /// cap, the metadata-resolution cap, and task priority order. All bookkeeping
    /// is done synchronously so the cap decision is atomic; the (async) engine
    /// calls are then fired without holding up the decision.
    private func schedule() {
        let profile = settings.selectedProfile
        let maxDownloads = profile.maxSimultaneousDownloads > 0 ? profile.maxSimultaneousDownloads : .max
        let maxMetadata = profile.maxMetadataResolutions > 0 ? profile.maxMetadataResolutions : .max

        var freeSlots = maxDownloads - runningSlots.count
        guard freeSlots > 0 else { return }

        var activeMetadata = tasks.filter { $0.status == .requestingMetadata }.count

        let candidates = tasks
            .filter { $0.status == .queued && !runningSlots.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.priority != rhs.priority
                    ? lhs.priority > rhs.priority      // higher priority first
                    : lhs.addedAt < rhs.addedAt        // then FIFO
            }

        var launches: [(id: UUID, resume: Bool)] = []
        for task in candidates {
            guard freeSlots > 0 else { break }
            let isMagnet = Self.isMagnet(task.source)
            // Respect the concurrent metadata-resolution cap: a magnet that would
            // resolve metadata is held back if the cap is already saturated.
            if isMagnet, activeMetadata >= maxMetadata { continue }

            runningSlots.insert(task.id)
            let resume = engineStarted.contains(task.id)
            if !resume { engineStarted.insert(task.id) }
            setOptimisticStatus(task.id)
            launches.append((task.id, resume))
            freeSlots -= 1
            if isMagnet { activeMetadata += 1 }
        }

        guard !launches.isEmpty else { return }
        publish()
        for launch in launches {
            Task { await self.launch(launch.id, resume: launch.resume) }
        }
    }

    /// Reflect the imminent start in the task's status before the engine emits
    /// its own status event, so observers see the queue move immediately.
    private func setOptimisticStatus(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if Self.isMagnet(tasks[i].source), !tasks[i].hasMetadata {
            tasks[i].status = .requestingMetadata
        } else {
            tasks[i].status = .downloading
        }
    }

    /// Perform the actual (async) engine hand-off for a promoted task.
    private func launch(_ id: UUID, resume: Bool) async {
        // The promotion may have been cancelled (paused/removed) between the
        // synchronous `schedule()` bookkeeping and this async hand-off. If so,
        // bail — and for a fresh start, undo the `engineStarted` mark so a later
        // resume re-adds the task cleanly rather than calling `engine.resume` on
        // a task the engine never received.
        guard let task = task(id), task.status != .paused, !task.status.isTerminal else {
            if !resume { engineStarted.remove(id) }
            runningSlots.remove(id)
            return
        }
        let engine = engine(for: task.source)
        // Ensure a live event subscription. On a fresh add this creates it; on a
        // resume after a terminal state (where the consumer was torn down) it
        // re-establishes it before the engine starts emitting again.
        if consumers[id] == nil { subscribe(id, to: engine) }
        if resume {
            await engine.resume(id)
        } else {
            await engine.add(task)
        }
    }

    // MARK: Event ingestion

    private func subscribe(_ id: UUID, to engine: any DownloadEngine) {
        let stream = engine.events(for: id)
        consumers[id] = Task { [weak self] in
            for await event in stream {
                await self?.apply(event, to: id)
            }
        }
    }

    /// Fold a single engine event into the stored task and republish.
    private func apply(_ event: EngineEvent, to id: UUID) {
        guard let i = index(of: id) else { return }

        switch event {
        case let .metadataResolved(name, totalBytes, files):
            if tasks[i].name.isEmpty { tasks[i].name = name }
            tasks[i].totalBytes = totalBytes
            tasks[i].files = files

        case let .progress(bytesDownloaded, bytesUploaded, downloadSpeed, uploadSpeed, connectionCount):
            tasks[i].bytesDownloaded = bytesDownloaded
            tasks[i].bytesUploaded = bytesUploaded
            tasks[i].downloadSpeed = downloadSpeed
            tasks[i].uploadSpeed = uploadSpeed
            tasks[i].connectionCount = connectionCount

        case let .fileProgress(fileID, bytesCompleted):
            if let f = tasks[i].files.firstIndex(where: { $0.id == fileID }) {
                tasks[i].files[f].bytesCompleted = bytesCompleted
            }

        case let .statusChanged(status):
            tasks[i].status = status
            handleStatusTransition(id, status)

        case .finished:
            break   // the subsequent .statusChanged carries the terminal/seeding state

        case let .failed(error):
            tasks[i].status = .failed(error)
            handleStatusTransition(id, .failed(error))

        case let .resumeDataUpdated(data):
            tasks[i].resumeData = data
        }

        // P1: persist only on meaningful transitions — never on raw progress (a
        // progress write 10×/sec/task is pure churn, and out-of-order detached
        // writes could clobber a freshly-written terminal state).
        switch event {
        case .progress, .fileProgress:
            break
        default:
            persist(tasks[i])
        }

        // P2: coalesce high-frequency progress snapshots; publish everything else
        // immediately so the queue visibly moves the instant status changes.
        switch event {
        case .progress, .fileProgress:
            throttledPublish()
        default:
            publish()
        }
    }

    /// React to a task leaving the active-download phase: free its slot, stamp a
    /// completion date, tear down the now-useless event subscription on a terminal
    /// state, and promote the next queued task.
    private func handleStatusTransition(_ id: UUID, _ status: DownloadStatus) {
        switch status {
        case .completed, .failed:
            runningSlots.remove(id)
            // The task is finished — stop consuming its stream so a completed
            // download doesn't leak a live consumer Task + continuation forever.
            // (Seeding keeps its subscription: it's still active.)
            consumers[id]?.cancel()
            consumers[id] = nil
            if status == .completed, let i = index(of: id), tasks[i].completedAt == nil {
                tasks[i].completedAt = Date()
            }
            schedule()
        case .seeding, .paused:
            runningSlots.remove(id)
            schedule()
        default:
            break
        }
    }

    // MARK: Helpers

    private func index(of id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    private func engine(for source: DownloadSource) -> any DownloadEngine {
        switch source.kind {
        case .http: return httpEngine
        case .torrent: return torrentEngine
        }
    }

    private static func isMagnet(_ source: DownloadSource) -> Bool {
        if case .magnet = source { return true }
        return false
    }

    /// A sensible — and **safe** — initial display name derived purely from the
    /// source. Every branch runs through ``DownloadTask/sanitizedName(_:fallback:)``
    /// so a hostile filename (e.g. a magnet `dn=../../.ssh/authorized_keys`) can
    /// never become a `name` that escapes the save directory.
    static func defaultName(for source: DownloadSource) -> String {
        switch source {
        case let .url(url):
            let last = url.lastPathComponent
            let base = (last.isEmpty || last == "/") ? (url.host ?? "download") : last
            return DownloadTask.sanitizedName(base, fallback: url.host ?? "download")
        case let .torrentFile(url):
            let name = url.deletingPathExtension().lastPathComponent
            return DownloadTask.sanitizedName(name, fallback: "torrent")
        case let .magnet(magnet):
            return magnetDisplayName(magnet) ?? "Magnet download"
        }
    }

    private static func magnetDisplayName(_ magnet: String) -> String? {
        guard
            let components = URLComponents(string: magnet),
            let value = components.queryItems?.first(where: { $0.name == "dn" })?.value,
            !value.isEmpty
        else { return nil }
        let cleaned = value.replacingOccurrences(of: "+", with: " ")
        return DownloadTask.sanitizedName(cleaned, fallback: "Magnet download")
    }
}
