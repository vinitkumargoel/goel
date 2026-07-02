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
    let ftpEngine: any DownloadEngine
    let sftpEngine: any DownloadEngine

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

    // Injected behind narrow `Sendable` ports (see `Ports/PlatformPorts.swift`) so
    // the scheduler's decision logic is testable; the inits default them to the real
    // adapters, so the app gets the live IOKit / DispatchSource / Process behaviour.

    /// Holds (at most one) "prevent idle sleep" assertion while transfers run, and
    /// reports the power source.
    let power: any PowerControlling

    /// Watches the configured folder for dropped `.torrent` files.
    let folderWatch: any FolderWatching

    /// Screens completed files with the configured external antivirus.
    let scanner: any FileScanning

    /// The periodic backup loop, when ``AppSettings/backupEnabled`` is on.
    var backupTask: Task<Void, Never>?

    // MARK: Download-window scheduling state

    /// The minute-resolution loop evaluating the time-of-day download window.
    var scheduleTask: Task<Void, Never>?

    /// Whether the download window is currently open. `true` whenever
    /// scheduling is disabled — the scheduler gates promotion on this.
    var scheduleWindowOpen = true

    /// Tasks the window-close transition paused, so reopening resumes exactly
    /// those — never downloads the user paused by hand.
    var schedulePausedIDs: Set<UUID> = []

    /// The profile that was active before the window switched to
    /// ``AppSettings/scheduleProfileName``, restored when the window closes.
    var preScheduleProfileName: String?

    /// The RSS feed polling loop, when any feed is enabled.
    var rssTask: Task<Void, Never>?

    /// The per-task scheduled-start loop, armed while any paused task carries a
    /// future ``DownloadTask/scheduledAt``.
    var scheduledStartTask: Task<Void, Never>?

    /// GUIDs/links already queued from feeds, so a poll never re-adds items.
    var rssSeenKeys: Set<String> = []

    // MARK: Network-awareness state

    /// Tasks paused by the expensive/constrained-network policy, so recovery
    /// resumes exactly those.
    var networkPausedIDs: Set<UUID> = []

    /// Whether the network policy currently holds the queue paused.
    var networkPaused = false

    /// The last path flags reported by the app layer, re-evaluated when the
    /// pause-on-expensive/constrained settings change.
    var lastPathExpensive = false
    var lastPathConstrained = false

    // MARK: Statistics state

    /// Lifetime/per-day transfer accounting, fed from progress deltas and
    /// persisted (throttled) alongside the settings.
    var stats = TransferStats()

    /// The last time ``stats`` was flushed to disk (flushes are throttled to
    /// ~30 s; status transitions flush immediately).
    var lastStatsFlush = Date.distantPast

    /// Per-task byte counts already folded into ``stats``. Kept separately from
    /// the task's own counters so a restart that begins above zero but below
    /// the previous absolute count re-bases and keeps recording, instead of
    /// silently losing the whole re-transferred interval.
    struct StatsMark {
        var down: Int64
        var up: Int64
    }
    var statsMarks: [UUID: StatsMark] = [:]

    // MARK: Persistence pipeline

    /// The serial persistence pipeline's state lives here; its behaviour lives in
    /// `DownloadManager+Persistence.swift`, hence `internal` rather than `private`.

    /// A single on-disk mutation, funnelled through the serial ``persistContinuation``.
    enum PersistOp: Sendable {
        case saveTask(DownloadTask)
        case deleteTask(UUID)
        case saveSettings(AppSettings)
        case saveStats(TransferStats)
        case saveHistory(HistoryEntry)
        case deleteHistory(UUID)
        case clearHistory
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
        ftpEngine: (any DownloadEngine)? = nil,
        sftpEngine: (any DownloadEngine)? = nil,
        settings: AppSettings = AppSettings(),
        store: PersistenceStore? = nil,
        power: any PowerControlling = SystemPowerControl(),
        folderWatch: any FolderWatching = SystemFolderWatch(),
        scanner: any FileScanning = ProcessFileScan()
    ) {
        self.httpEngine = httpEngine
        self.torrentEngine = torrentEngine
        self.hlsEngine = hlsEngine ?? HLSEngine(profile: settings.effectiveProfile)
        self.ftpEngine = ftpEngine ?? FTPEngine(profile: settings.effectiveProfile)
        self.sftpEngine = sftpEngine ?? SFTPEngine(profile: settings.effectiveProfile)
        self.settings = settings
        self.store = store
        self.power = power
        self.folderWatch = folderWatch
        self.scanner = scanner
        if store != nil {
            let (stream, continuation) = AsyncStream<PersistOp>.makeStream(bufferingPolicy: .unbounded)
            self.persistStream = stream
            self.persistContinuation = continuation
        }
    }

    /// Convenience initialiser wiring the production ``HTTPEngine`` and the
    /// ``MockTorrentEngine``.
    public init(
        settings: AppSettings = AppSettings(),
        store: PersistenceStore? = nil,
        power: any PowerControlling = SystemPowerControl(),
        folderWatch: any FolderWatching = SystemFolderWatch(),
        scanner: any FileScanning = ProcessFileScan()
    ) {
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
        self.ftpEngine = FTPEngine(profile: settings.effectiveProfile)
        self.sftpEngine = SFTPEngine(profile: settings.effectiveProfile)
        self.settings = settings
        self.store = store
        self.power = power
        self.folderWatch = folderWatch
        self.scanner = scanner
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

        if let savedStats = try? store.loadStats() { stats = savedStats }

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
        updateDownloadSchedule()
        updateRSSSchedule()
        armScheduledStarts()
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

    /// The lifetime/per-day transfer statistics.
    public var currentStats: TransferStats { stats }

    // MARK: Download history

    /// The archived completed downloads, newest first. Reads the store directly
    /// (writes flow through the serial pipeline, so an entry archived a moment
    /// ago may trail by one flush — fine for a browsing UI).
    public func history(limit: Int = 1000) -> [HistoryEntry] {
        guard let store else { return [] }
        return (try? store.loadHistory(limit: limit)) ?? []
    }

    /// Delete one archived entry.
    public func removeHistoryEntry(_ id: UUID) {
        persistHistoryRemoval(id)
    }

    /// Wipe the download history archive.
    public func clearHistory() {
        persistHistoryClear()
    }

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
    /// `startPaused` creates the task directly in `.paused` and skips the
    /// scheduler entirely — the race-free form of "add then pause" (an
    /// add-then-pause pair can lose to the scheduler's optimistic promotion,
    /// leaving the engine actively downloading a task the caller wanted held).
    @discardableResult
    public func add(
        source: DownloadSource,
        saveDirectory: String? = nil,
        priority: FilePriority = .normal,
        expectedChecksum: Checksum? = nil,
        startPaused: Bool = false,
        scheduledAt: Date? = nil,
        mirrors: [String]? = nil,
        suggestedName: String? = nil
    ) -> DownloadTask {
        if let existing = tasks.first(where: { $0.source.dedupKey == source.dedupKey }) {
            return existing
        }
        // A future start time implies "hold it until then" — same race-free
        // create-paused path as `startPaused`.
        let holdPaused = startPaused || scheduledAt != nil
        let directory = saveDirectory ?? defaultDirectory(for: source)
        // Resolve the on-disk name conflict at creation time only — never on
        // resume/retry, which reuse the stored name and rely on the partial file
        // still living at the same path. Torrent names are placeholders until
        // metadata resolves, so the policy applies to HTTP downloads only.
        // A caller-supplied name (metalink `name=`) is sanitized like any
        // untrusted input before it can influence the on-disk path.
        let baseName = suggestedName.map {
            DownloadTask.sanitizedName($0, fallback: Self.defaultName(for: source))
        } ?? Self.defaultName(for: source)
        let name: String
        if source.kind == .http || source.kind == .hls {
            name = Self.resolveName(baseName,
                                    in: directory,
                                    policy: settings.existingFileReaction)
        } else {
            name = baseName
        }
        let task = DownloadTask(
            source: source,
            name: name,
            saveDirectory: directory,
            status: holdPaused ? .paused : .queued,
            priority: priority,
            expectedChecksum: expectedChecksum,
            scheduledAt: scheduledAt,
            mirrors: Self.sanitizedMirrors(mirrors, primary: source)
        )
        tasks.append(task)
        persist(task)
        publish()
        if !holdPaused { schedule() }
        if scheduledAt != nil { armScheduledStarts() }
        return task
    }

    /// Mirrors are untrusted input from add forms / metalink files: keep only
    /// http(s) URLs, drop duplicates and the primary itself, cap the count.
    static func sanitizedMirrors(_ raw: [String]?, primary: DownloadSource) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }
        var seen: Set<String> = [primary.locator]
        var result: [String] = []
        for line in raw {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(url.absoluteString)
            if result.count >= 10 { break }
        }
        return result.isEmpty ? nil : result
    }

    /// Resolve a source's metadata for the add-confirmation screen, *without*
    /// adding anything to the queue. HTTP/HLS probe the server for name + size;
    /// torrents/magnets fetch the name, total size and file list (then discard the
    /// throwaway handle). Always returns a preview — on failure it carries a `note`
    /// and the best-effort name so the user can still choose to start.
    public func resolveMetadata(for source: DownloadSource, saveDirectory: String? = nil) async -> DownloadPreview {
        let directory = saveDirectory ?? defaultDirectory(for: source)
        let fallbackName = Self.defaultName(for: source)
        let kind = source.kind
        let engine = engine(for: source)

        // The seam: ask the engine to resolve, never downcasting to a concrete
        // type. Each engine reports what it could (or couldn't) find; the manager
        // folds that into the preview, applying its own fallback name and the
        // kind-specific note.
        guard let meta = await engine.resolveMetadata(for: source, in: directory) else {
            // Nil means the engine couldn't resolve this time (server unreachable /
            // no peers answered) or doesn't probe at all. Only an engine that
            // ADVERTISES metadata resolution earns an explanatory note; otherwise
            // the preview is a plain best-effort name.
            let note = engine.capabilities.contains(.resolvesMetadata) ? Self.unresolvedNote(for: kind) : nil
            return DownloadPreview(
                source: source, suggestedName: fallbackName, totalBytes: nil,
                isEstimatedSize: kind == .hls, kind: kind, note: note)
        }

        let name = meta.name.isEmpty ? fallbackName : meta.name
        return DownloadPreview(
            source: source, suggestedName: name, totalBytes: meta.totalBytes,
            isEstimatedSize: meta.isEstimatedSize, files: meta.files, kind: kind,
            note: meta.reachable ? nil : Self.unresolvedNote(for: kind),
            suggestedChecksum: meta.suggestedChecksum)
    }

    /// The non-fatal note shown when a source's metadata couldn't be resolved up
    /// front. Kind-specific so the wording matches the failure mode; the user can
    /// always still start the download.
    private static func unresolvedNote(for kind: DownloadKind) -> String? {
        switch kind {
        case .http, .ftp, .sftp:
            return "Couldn’t reach the server — it may still work when you start."
        case .torrent:
            return "No peers answered in time, so the file list isn’t available yet. You can still start — it will resolve while downloading."
        case .hls:
            return nil
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
        tasks[i].connections = nil
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
        tasks[i].scheduledAt = nil   // starting now supersedes any scheduled start
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
        tasks[i].scanVerdict = nil
        tasks[i].scheduledAt = nil
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
        statsMarks[id] = nil
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
        scheduleTask?.cancel()
        scheduleTask = nil
        rssTask?.cancel()
        rssTask = nil
        scheduledStartTask?.cancel()
        scheduledStartTask = nil
        let folderWatch = self.folderWatch
        Task { await folderWatch.stop() }
        power.setPreventSleep(false)
        // Flush the stats then let the worker drain any queued writes and exit.
        persistStats(force: true)
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

    /// Apply a settings change in one deep call: mutate a copy of the current
    /// ``settings``, push it through the full ``updateSettings(_:)`` cascade, and
    /// return the committed value — so a caller never needs a separate
    /// read-after-write round-trip to learn what was actually stored.
    @discardableResult
    public func apply(_ change: @Sendable (inout AppSettings) -> Void) async -> AppSettings {
        var copy = settings
        change(&copy)
        await updateSettings(copy)
        return settings
    }

    /// Switch the active traffic profile. Delegates to ``apply(_:)`` so the new
    /// limits reach both engines and the scheduler re-runs (the simultaneous cap
    /// may have changed), and returns the committed settings.
    @discardableResult
    public func setProfile(_ name: String) async -> AppSettings {
        await apply { $0.selectedProfileName = name }
    }

    /// Toggle the "snail" speed limit. When disabled, speeds become unlimited.
    /// Delegates to ``apply(_:)`` so both engines are re-applied live, and returns
    /// the committed settings.
    @discardableResult
    public func setSpeedLimitEnabled(_ enabled: Bool) async -> AppSettings {
        await apply { $0.speedLimitEnabled = enabled }
    }

    /// Change the default save folder for future downloads, returning the
    /// committed settings. The default-folder rule is read live by ``add`` for
    /// each new download, so this only persists and publishes — it deliberately
    /// does NOT run the full ``updateSettings`` cascade (which would needlessly
    /// re-arm the watch-folder/backup timers and re-run the scheduler on a
    /// directory-only change).
    @discardableResult
    public func setDefaultSaveDirectory(_ path: String) async -> AppSettings {
        settings.defaultSaveDirectory = path
        persistSettings()
        publish()
        return settings
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
        updateDownloadSchedule()
        updateRSSSchedule()
        await applyNetworkPolicy(expensive: lastPathExpensive, constrained: lastPathConstrained)
        publish()
        schedule()
    }

    /// Switch a torrent between sequential (in-order, streamable) and
    /// rarest-first piece download. No-op for HTTP/HLS tasks.
    public func setSequential(_ sequential: Bool, task id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await engine(for: task.source).setSequential(sequential, task: id)
        if let i = index(of: id) {
            tasks[i].sequentialDownload = sequential
            persist(tasks[i])
        }
        publish()
    }

    /// Set (or clear, with nil/0) a per-task download cap in bytes/sec. Applied
    /// on the task's next launch/resume; the global profile ceiling still holds.
    public func setTaskSpeedLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) async {
        guard let i = index(of: id) else { return }
        tasks[i].speedLimitBytesPerSec = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
        persist(tasks[i])
        publish()
    }

    // MARK: Export / Import

    /// A self-contained snapshot of the whole app: settings + every task with
    /// its full state (progress, status, resume cursor). The JSON counterpart of
    /// the locator-only text export in the File menu.
    public func exportEnvelope() throws -> Data {
        let envelope = AppExport(settings: settings, tasks: tasks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(envelope)
    }

    /// Import a snapshot produced by ``exportEnvelope()``: adopt its settings and
    /// merge its tasks (skipping sources already in the queue). Restored tasks
    /// come back `.paused` — like ``restore()`` — so nothing starts by surprise.
    /// Returns the number of tasks actually added.
    ///
    /// Security: a backup file is untrusted input. Every task is re-sanitized,
    /// and settings that can execute code or open network listeners (remote
    /// access, post-download script, antivirus executable, RSS feeds, watch
    /// folder) are NEVER adopted from a file — the current values are kept, so
    /// a hostile "backup" can't silently turn the app into an exfiltration or
    /// remote-control vector.
    @discardableResult
    public func importEnvelope(_ data: Data) async throws -> Int {
        let envelope = try JSONDecoder().decode(AppExport.self, from: data)
        var added = 0
        for imported in envelope.tasks {
            let task = PersistenceStore.sanitizedForImport(imported)
            guard !tasks.contains(where: { $0.source.dedupKey == task.source.dedupKey }) else { continue }
            var t = task
            switch t.status {
            case .downloading, .verifying, .requestingMetadata, .queued, .seeding:
                t.status = .paused
            default:
                break
            }
            t.downloadSpeed = 0
            t.uploadSpeed = 0
            t.connectionCount = 0
            t.connections = nil
            tasks.append(t)
            persist(t)
            added += 1
        }
        await updateSettings(Self.sanitizedImportedSettings(envelope.settings, current: settings))
        return added
    }

    /// Imported settings with every security-sensitive field forced back to
    /// the CURRENT value. `internal` so tests can drive the matrix directly.
    static func sanitizedImportedSettings(_ imported: AppSettings,
                                          current: AppSettings) -> AppSettings {
        var safe = imported
        // Remote code / process execution.
        safe.postDownloadScriptEnabled = current.postDownloadScriptEnabled
        safe.postDownloadScriptPath = current.postDownloadScriptPath
        safe.postDownloadScriptArgs = current.postDownloadScriptArgs
        safe.antivirusEnabled = current.antivirusEnabled
        safe.antivirusExecutablePath = current.antivirusExecutablePath
        safe.antivirusArgumentTemplate = current.antivirusArgumentTemplate
        safe.antivirusScanner = current.antivirusScanner
        // Network listeners and auto-fetch surfaces.
        safe.remoteAccessEnabled = current.remoteAccessEnabled
        safe.remotePort = current.remotePort
        safe.remoteToken = current.remoteToken
        safe.remoteAllowLAN = current.remoteAllowLAN
        safe.rssFeeds = current.rssFeeds
        safe.btWatchFolderEnabled = current.btWatchFolderEnabled
        safe.btWatchFolderPath = current.btWatchFolderPath
        safe.btWatchStartWithoutConfirmation = current.btWatchStartWithoutConfirmation
        safe.updateFeedURL = current.updateFeedURL
        return safe
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
        case .ftp: return ftpEngine
        case .sftp: return sftpEngine
        }
    }
}
