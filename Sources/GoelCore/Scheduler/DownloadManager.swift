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
/// Beyond raw queueing it is the integration hub for every cross-cutting setting:
/// it re-applies the engines' network/session configuration, holds a power
/// assertion while downloads run, drives the watch-folder, schedules periodic
/// backups, runs the optional antivirus screen on completed files, and resolves
/// each download's save directory from the configured folder rule.
///
/// It is an `actor`, so all queue bookkeeping is serialized and it is `Sendable`
/// for free. Engines are themselves actors, hence the `await`s. No UI framework
/// is imported — the manager is pure model logic.
public actor DownloadManager {

    // MARK: Engines

    // `internal` (not `private`) so the `+EngineConfig` / `+Scheduling` / `+Events`
    // extensions in sibling files can reach them. Only this file assigns them.
    let httpEngine: any DownloadEngine
    let torrentEngine: any DownloadEngine
    let hlsEngine: any DownloadEngine

    // MARK: State

    /// The unified, ordered task list. The single source of truth.
    /// `internal` (not `private`) so the `+Persistence` / `+SideEffects`
    /// extensions in sibling files can read it; only this file mutates it.
    var tasks: [DownloadTask] = []

    /// User configuration (active profile, snail flag, default folder, plus the
    /// General/Network/BitTorrent/Notification/Power/Backup/Antivirus panes).
    /// `internal` so the cross-cutting extensions can read it.
    var settings: AppSettings

    /// Optional on-disk store. When present, the queue and settings survive quit
    /// & relaunch. Writes are dispatched off the actor so disk I/O never blocks
    /// queue bookkeeping (and never the main actor).
    let store: PersistenceStore?

    /// Tasks currently occupying a download slot — i.e. handed to an engine and
    /// still in an active download phase (`.requestingMetadata` / `.downloading`).
    /// A task leaves this set the moment it pauses, fails, completes, or starts
    /// seeding, which is when a queued task may be promoted.
    /// `internal` so `+Scheduling` / `+Events` can manage slot accounting.
    var runningSlots: Set<UUID> = []

    /// Tasks that have been `add`-ed to their engine at least once. Distinguishes
    /// a fresh start (`engine.add`) from a resume (`engine.resume`).
    var engineStarted: Set<UUID> = []

    /// Per-task event-stream consumers.
    var consumers: [UUID: Task<Void, Never>] = [:]

    /// Snapshot observers.
    private var observers: [UUID: AsyncStream<[DownloadTask]>.Continuation] = [:]

    // MARK: Side-effect services

    /// Holds (at most one) "prevent idle sleep" assertion while transfers run.
    let powerManager = PowerManager()

    /// Watches the configured folder for dropped `.torrent` files.
    let watchFolder = WatchFolderMonitor()

    /// The periodic backup loop, when ``AppSettings/backupEnabled`` is on.
    var backupTask: Task<Void, Never>?

    // MARK: Persistence pipeline

    /// The serial persistence pipeline's state lives here; its behaviour lives in
    /// `DownloadManager+Persistence.swift`, hence `internal` rather than `private`.

    /// A single on-disk mutation, funnelled through the serial ``persistContinuation``.
    enum PersistOp: Sendable {
        case saveTask(DownloadTask)
        case deleteTask(UUID)
        case saveSettings(AppSettings)
    }

    /// The (one-shot) source of the serial persistence stream, consumed the first
    /// time a write is enqueued. `nil` once started, or when there is no store.
    var persistStream: AsyncStream<PersistOp>?

    /// The write side of the serial persistence pipeline.
    var persistContinuation: AsyncStream<PersistOp>.Continuation?

    /// The single worker draining ``persistStream`` in enqueue order.
    var persistWorker: Task<Void, Never>?

    /// Whether ``persistWorker`` has been started.
    var persistStarted = false

    // MARK: Init

    /// Inject the two engines (typed as `any DownloadEngine` so a real
    /// libtorrent shim can replace the mock without touching the scheduler).
    public init(
        httpEngine: any DownloadEngine,
        torrentEngine: any DownloadEngine,
        hlsEngine: (any DownloadEngine)? = nil,
        settings: AppSettings = AppSettings(),
        store: PersistenceStore? = nil
    ) {
        self.httpEngine = httpEngine
        self.torrentEngine = torrentEngine
        self.hlsEngine = hlsEngine ?? HLSEngine(profile: settings.effectiveProfile)
        self.settings = settings
        self.store = store
        if store != nil {
            let (stream, continuation) = AsyncStream<PersistOp>.makeStream(bufferingPolicy: .unbounded)
            self.persistStream = stream
            self.persistContinuation = continuation
        }
    }

    /// Convenience initialiser wiring the production ``HTTPEngine`` and the
    /// ``MockTorrentEngine``.
    public init(settings: AppSettings = AppSettings(), store: PersistenceStore? = nil) {
        self.httpEngine = HTTPEngine(profile: settings.effectiveProfile)
        self.torrentEngine = TorrentEngine(
            profile: settings.effectiveProfile,
            config: TorrentEngine.SessionConfig(
                enableDHT: settings.btEnableDHT,
                enableLSD: settings.btEnableLPD,
                enableUTP: settings.btEnableUTP,
                encryptionMode: settings.btEncryptionMode
            )
        )
        self.hlsEngine = HLSEngine(profile: settings.effectiveProfile)
        self.settings = settings
        self.store = store
        if store != nil {
            let (stream, continuation) = AsyncStream<PersistOp>.makeStream(bufferingPolicy: .unbounded)
            self.persistStream = stream
            self.persistContinuation = continuation
        }
    }

    // MARK: Persistence

    /// Restore the queue and settings from the on-disk ``store`` (if any).
    ///
    /// Call this once, right after construction, before adding new downloads.
    /// Persisted settings replace the in-memory ones; persisted tasks are loaded
    /// with their `bytesDownloaded`/`resumeData`/error/seeding state intact.
    /// Tasks that were mid-flight (downloading / requesting metadata / queued) —
    /// and tasks that were seeding — come back `.paused` so the user explicitly
    /// resumes them (a restored seeding torrent runs no engine, so showing
    /// "Seeding" would be a lie; paused is honest and resumable). Terminal and
    /// already-paused tasks keep their state. No engine work is started here; the
    /// restored settings are re-applied to the engines and side-effect services.
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
            case .downloading, .verifying, .requestingMetadata, .queued, .seeding:
                t.status = .paused
            default:
                break   // paused / completed / failed are preserved
            }
            t.downloadSpeed = 0
            t.uploadSpeed = 0
            t.connectionCount = 0
            return t
        }

        // Reflect any status normalisation back to disk.
        for task in tasks { persist(task) }
        await applyEngineConfigs()
        await updateWatchFolder()
        updateBackupSchedule()
        updatePowerAssertion()
        publish()
    }

    /// A human-readable persistence problem, surfaced to the UI (a failed disk
    /// write means the queue silently diverges from disk — the user must know).
    /// `internal` so `notePersistenceError` (in `+Persistence`) can set it.
    var persistenceWarning: String?

    // The persistence pipeline's behaviour (currentPersistenceWarning,
    // notePersistenceError, persist, persistSettings, persistRemoval) lives in
    // `DownloadManager+Persistence.swift`.

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

    /// `internal` so `+Scheduling` / `+Events` can republish after mutating state.
    func publish() {
        let snapshot = tasks
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    /// Throttle progress-driven snapshots to ~10 Hz. Structural/status changes
    /// always publish immediately (via ``publish()``); only the high-frequency
    /// `.progress`/`.fileProgress` stream is coalesced, so the UI isn't flooded
    /// with whole-list snapshots dozens of times a second per task.
    private var lastProgressPublish = Date.distantPast
    /// `internal` so `+Events` can coalesce progress snapshots.
    func throttledPublish() {
        let now = Date()
        if now.timeIntervalSince(lastProgressPublish) >= 0.1 {
            lastProgressPublish = now
            publish()
        }
    }

    // MARK: Public actions

    /// Add a download. If a task whose source resolves to the same identity
    /// (``DownloadSource/dedupKey`` — the infohash for a magnet) already exists it
    /// is **not** duplicated — the existing task is returned instead. When no
    /// explicit `saveDirectory` is given the folder is chosen per the configured
    /// ``AppSettings/defaultFolderRule``. The new task starts `.queued`; the
    /// scheduler promotes it when a slot is free.
    @discardableResult
    public func add(
        source: DownloadSource,
        saveDirectory: String? = nil,
        priority: FilePriority = .normal,
        expectedChecksum: Checksum? = nil
    ) -> DownloadTask {
        if let existing = tasks.first(where: { $0.source.dedupKey == source.dedupKey }) {
            return existing
        }
        let directory = saveDirectory ?? defaultDirectory(for: source)
        // Resolve the on-disk name conflict at creation time only — never on
        // resume/retry, which reuse the stored name and rely on the partial file
        // still living at the same path. Torrent names are placeholders until
        // metadata resolves, so the policy applies to HTTP downloads only.
        let name: String
        if source.kind == .http || source.kind == .hls {
            name = Self.resolveName(Self.defaultName(for: source),
                                    in: directory,
                                    policy: settings.existingFileReaction)
        } else {
            name = Self.defaultName(for: source)
        }
        let task = DownloadTask(
            source: source,
            name: name,
            saveDirectory: directory,
            status: .queued,
            priority: priority,
            expectedChecksum: expectedChecksum
        )
        tasks.append(task)
        persist(task)
        publish()
        schedule()
        return task
    }

    /// Resolve a source's metadata for the add-confirmation screen, *without*
    /// adding anything to the queue. HTTP/HLS probe the server for name + size;
    /// torrents/magnets fetch the name, total size and file list (then discard the
    /// throwaway handle). Always returns a preview — on failure it carries a `note`
    /// and the best-effort name so the user can still choose to start.
    public func resolveMetadata(for source: DownloadSource, saveDirectory: String? = nil) async -> DownloadPreview {
        let directory = saveDirectory ?? defaultDirectory(for: source)
        let fallbackName = Self.defaultName(for: source)

        switch source.kind {
        case .http:
            guard case .url(let url) = source, let http = httpEngine as? HTTPEngine else {
                return DownloadPreview(source: source, suggestedName: fallbackName,
                                       totalBytes: nil, kind: .http)
            }
            let r = await http.resolveMetadata(for: url, currentName: fallbackName)
            return DownloadPreview(
                source: source, suggestedName: r.name, totalBytes: r.totalBytes, kind: .http,
                note: r.reachable ? nil : "Couldn’t reach the server — it may still work when you start.")

        case .torrent:
            guard let torrent = torrentEngine as? TorrentEngine else {
                return DownloadPreview(source: source, suggestedName: fallbackName,
                                       totalBytes: nil, kind: .torrent)
            }
            if let m = await torrent.resolveMetadata(for: source, saveDirectory: directory) {
                let name = m.name.isEmpty ? fallbackName : DownloadTask.sanitizedName(m.name)
                return DownloadPreview(source: source, suggestedName: name, totalBytes: m.totalBytes,
                                       files: m.files, kind: .torrent)
            }
            return DownloadPreview(
                source: source, suggestedName: fallbackName, totalBytes: nil, kind: .torrent,
                note: "No peers answered in time, so the file list isn’t available yet. You can still start — it will resolve while downloading.")

        case .hls:
            // HLS size is only knowable by walking the playlist; show the name now
            // and let the exact size settle once the download starts.
            return DownloadPreview(source: source, suggestedName: fallbackName,
                                   totalBytes: nil, isEstimatedSize: true, kind: .hls)
        }
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
            updatePowerAssertion()
            publish()
            schedule()
            return
        }
        tasks[i].status = .paused
        tasks[i].downloadSpeed = 0
        tasks[i].uploadSpeed = 0
        persist(tasks[i])
        updatePowerAssertion()
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
        updatePowerAssertion()
        publish()
        schedule()
    }

    /// Tear down all live subscriptions, observers and side-effect services. Call
    /// before releasing the manager so nothing is left dangling.
    public func shutdown() {
        for consumer in consumers.values { consumer.cancel() }
        consumers.removeAll()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
        backupTask?.cancel()
        backupTask = nil
        let watchFolder = self.watchFolder
        Task { await watchFolder.stop() }
        powerManager.setPreventSleep(false)
        // Let the persistence worker drain any queued writes, then exit.
        persistContinuation?.finish()
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

    /// Switch the active traffic profile. Delegates to ``updateSettings(_:)`` so
    /// the new limits reach both engines and the scheduler re-runs (the
    /// simultaneous cap may have changed).
    public func setProfile(_ name: String) async {
        var updated = settings
        updated.selectedProfileName = name
        await updateSettings(updated)
    }

    /// Toggle the "snail" speed limit. When disabled, speeds become unlimited.
    /// Delegates to ``updateSettings(_:)`` so both engines are re-applied live.
    public func setSpeedLimitEnabled(_ enabled: Bool) async {
        var updated = settings
        updated.speedLimitEnabled = enabled
        await updateSettings(updated)
    }

    /// Change the default save folder for future downloads.
    public func setDefaultSaveDirectory(_ path: String) {
        settings.defaultSaveDirectory = path
        persistSettings()
        publish()
    }

    /// Replace the entire settings object and re-apply every dependent subsystem:
    /// engine bandwidth/connection limits, HTTP network config, torrent session
    /// config, the power assertion, the watch-folder, the backup schedule, and the
    /// scheduler. The default-folder rule needs no re-application here — it is read
    /// live by ``add(source:saveDirectory:priority:)`` for each new download.
    public func updateSettings(_ newSettings: AppSettings) async {
        settings = newSettings
        persistSettings()
        await applyEngineConfigs()
        updatePowerAssertion()
        await updateWatchFolder()
        updateBackupSchedule()
        publish()
        schedule()
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

    // Engine limits/config (applyLimits, applyEngineConfigs, reapplyHTTPBudget)
    // live in `DownloadManager+EngineConfig.swift`.

    // MARK: Default-folder rule

    /// Resolve the save directory for a new download from
    /// ``AppSettings/defaultFolderRule``, using ``AppSettings/defaultSaveDirectory``
    /// as the base/fixed folder.
    private func defaultDirectory(for source: DownloadSource) -> String {
        let base = settings.defaultSaveDirectory
        switch settings.defaultFolderRule {
        case "byType", "automatic":
            return (base as NSString).appendingPathComponent(Self.categoryFolder(for: source))
        case "bySource":
            let bucket = source.kind == .torrent ? "Torrents" : "HTTP Downloads"
            return (base as NSString).appendingPathComponent(bucket)
        default:   // "fixed"
            return base
        }
    }

    // Cross-cutting side effects (power assertion, watch folder, periodic backup,
    // and post-completion hooks) live in `DownloadManager+SideEffects.swift`.
    //
    // Queue promotion (schedule / setOptimisticStatus / launch) lives in
    // `DownloadManager+Scheduling.swift`; engine-event folding (subscribe / apply /
    // handleStatusTransition) lives in `DownloadManager+Events.swift`.

    // MARK: Helpers

    /// `internal` so the `+Scheduling` / `+Events` extensions can locate a task.
    func index(of id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    /// `internal` so the `+Scheduling` extension can route to the right engine.
    func engine(for source: DownloadSource) -> any DownloadEngine {
        switch source.kind {
        case .http: return httpEngine
        case .torrent: return torrentEngine
        case .hls: return hlsEngine
        }
    }
}
