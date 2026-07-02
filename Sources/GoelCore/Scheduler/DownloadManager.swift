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

    /// The consolidated automation memory — the window/network paused-id ledgers,
    /// the pre-window profile, and the RSS seen-keys — that the pure
    /// ``AutomationCore`` reads and hands back each tick. It replaces the five
    /// parallel ledgers this actor used to keep (which could drift apart).
    var automationMemory = AutomationCore.Memory()

    /// The RSS feed polling loop, when any feed is enabled.
    var rssTask: Task<Void, Never>?

    /// The per-task scheduled-start loop, armed while any paused task carries a
    /// future ``DownloadTask/scheduledAt``.
    var scheduledStartTask: Task<Void, Never>?

    /// The periodic "remote resource changed?" checker for finished HTTP tasks,
    /// armed only while ``AppSettings/autoRedownloadOnRemoteChange`` is on.
    var redownloadTask: Task<Void, Never>?

    // MARK: Network-awareness state

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
    /// silently losing the whole re-transferred interval. The re-base rule lives
    /// in ``StatsAccumulator``.
    typealias StatsMark = StatsAccumulator.Mark
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
        updateRedownloadSchedule()
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
        suggestedName: String? = nil,
        totalBytes: Int64? = nil,
        files: [TransferFile] = [],
        deselectedFileIDs: [Int]? = nil
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
            PathSafety.sanitizedName($0, fallback: Self.defaultName(for: source))
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
            // Seed the size/file list already resolved on the add screen so the
            // task appears fully-formed instead of re-showing a "gathering" state
            // for facts we already have. The engine still reconciles from truth as
            // it runs; these are just a correct initial display.
            totalBytes: totalBytes,
            status: holdPaused ? .paused : .queued,
            priority: priority,
            files: files,
            expectedChecksum: expectedChecksum,
            scheduledAt: scheduledAt,
            mirrors: Self.sanitizedMirrors(mirrors, primary: source),
            initialSkipFileIDs: (deselectedFileIDs?.isEmpty ?? true) ? nil : deselectedFileIDs
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
        redownloadTask?.cancel()
        redownloadTask = nil
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
        updateRedownloadSchedule()
        await applyNetworkPolicy(expensive: lastPathExpensive, constrained: lastPathConstrained)
        publish()
        schedule()
    }

    /// Switch a torrent between sequential (in-order, streamable) and
    /// rarest-first piece download. No-op for HTTP/HLS tasks.
    public func setSequential(_ sequential: Bool, task id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        // Only torrent engines control piece order; the intentional capability
        // query replaces the old base-protocol no-op. The model flag is set
        // regardless (it drives the streamability check).
        await (engine(for: task.source) as? TorrentControlling)?.setSequential(sequential, task: id)
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

    /// Cap one torrent's upload rate in bytes/sec (nil/0 = uncapped), applied live.
    public func setTaskUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.setUploadLimit(bytesPerSec, task: id)
        // Re-resolve the index AFTER the actor hop: `tasks` may have been mutated
        // (e.g. a concurrent remove) while suspended, so a pre-await index could
        // now point past the end or at a different task.
        if let i = index(of: id) {
            tasks[i].uploadLimitBytesPerSec = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
            persist(tasks[i])
        }
        publish()
    }

    /// Set (or clear, with nil) a per-torrent seed-ratio limit. When seeding
    /// reaches it, the engine stops the torrent and marks it completed.
    public func setSeedRatioLimit(_ ratio: Double?, task id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.setSeedRatioLimit(ratio, task: id)
        // Re-resolve the index after the actor hop (see setTaskUploadLimit).
        if let i = index(of: id) {
            tasks[i].seedRatioLimit = (ratio ?? 0) > 0 ? ratio : nil
            persist(tasks[i])
        }
        publish()
    }

    /// Re-verify a torrent's on-disk data against its piece hashes.
    public func forceRecheck(_ id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.forceRecheck(id)
    }

    /// Force a torrent to re-announce to its trackers immediately.
    public func forceReannounce(_ id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.forceReannounce(id)
    }

    /// Assign (or clear, with nil/empty) a free-form category label for grouping.
    public func setLabel(_ label: String?, task id: DownloadTask.ID) async {
        guard let i = index(of: id) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        tasks[i].label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persist(tasks[i])
        publish()
    }

    /// Replace a task's tag set (trimmed, de-duped case-insensitively, order-stable).
    public func setTags(_ tags: [String], task id: DownloadTask.ID) async {
        guard let i = index(of: id) else { return }
        let cleaned = Self.normalizeTags(tags)
        tasks[i].tags = cleaned.isEmpty ? nil : cleaned
        persist(tasks[i])
        publish()
    }

    /// Set (or clear, with nil/empty) a free-form note on a task.
    public func setNote(_ note: String?, task id: DownloadTask.ID) async {
        guard let i = index(of: id) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        tasks[i].note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persist(tasks[i])
        publish()
    }

    /// Set the per-task `Referer` and extra request headers (HTTP downloads).
    /// Reserved and malformed header names are dropped; nil/empty clears each
    /// field. Returns the reserved header names that were ignored, so the UI can
    /// tell the user rather than silently discarding them.
    @discardableResult
    public func setRequestOptions(referer: String?, headers: [String: String]?,
                                  task id: DownloadTask.ID) async -> [String] {
        guard let i = index(of: id) else { return [] }
        var r = referer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A Referer carrying CR/LF/NUL could split the request — never store it.
        if Self.hasHeaderControlChars(r) { r = "" }
        tasks[i].referer = r.isEmpty ? nil : r
        let raw = headers ?? [:]
        let cleaned = Self.sanitizedHeaders(raw)
        tasks[i].requestHeaders = cleaned.isEmpty ? nil : cleaned
        persist(tasks[i])
        publish()
        // Names the user supplied that we refused to store (reserved only —
        // control-char/empty are malformed, not "reserved", and reported as such
        // is more confusing than useful).
        return raw.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { Self.reservedHeaderNames.contains($0) }
            .sorted()
    }

    /// The outcome of a ``rename(_:to:)``, distinguishing each rejection cause so
    /// the UI can show an accurate message instead of one catch-all string.
    public enum RenameResult: Sendable, Equatable {
        case renamed(String)      // applied, carrying the final (possibly deduped) name
        case unchanged            // the new name equalled the old — a no-op success
        case notFound             // no task with that id
        case unsupported          // torrents own their on-disk layout
        case active               // can't rename out from under the live writer
        case ioError(String)      // the disk move failed (permissions, full, …)
    }

    /// Rename a download's output file and display name. Renames the file on disk
    /// (never clobbering an existing one — appends ` (n)` if needed). Not supported
    /// for torrents (libtorrent owns their on-disk layout) or while a task is
    /// actively transferring (the writer holds the old path).
    @discardableResult
    public func rename(_ id: DownloadTask.ID, to newName: String) async -> RenameResult {
        guard let i = index(of: id) else { return .notFound }
        let task = tasks[i]
        guard task.kind != .torrent else { return .unsupported }
        guard !task.status.isActive else { return .active }
        let sanitized = PathSafety.sanitizedName(newName, fallback: task.name)
        guard sanitized != task.name else { return .unchanged }
        let fm = FileManager.default
        let dir = task.saveDirectory
        let finalName = PathSafety.uniqueName(base: sanitized, in: dir)
        let oldPath = (dir as NSString).appendingPathComponent(task.name)
        let newPath = (dir as NSString).appendingPathComponent(finalName)
        if fm.fileExists(atPath: oldPath) {
            do { try fm.moveItem(atPath: oldPath, toPath: newPath) }
            catch { return .ioError(error.localizedDescription) }
        }
        tasks[i].name = finalName
        persist(tasks[i])
        publish()
        return .renamed(finalName)
    }

    /// Trim, drop empties, and de-duplicate tags case-insensitively (order-stable).
    static func normalizeTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in raw {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Header names the transport manages itself; a user value here is ignored.
    static let reservedHeaderNames: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding", "keep-alive",
        "upgrade", "te", "trailer", "referer", "authorization", "proxy-authorization",
        "proxy-connection"
    ]

    /// Trim names/values, and drop reserved, empty, or control-char-bearing
    /// headers (a `\r`/`\n`/NUL anywhere would let a value split the request).
    static func sanitizedHeaders(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw {
            let name = k.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !reservedHeaderNames.contains(name.lowercased()),
                  !hasHeaderControlChars(name), !hasHeaderControlChars(value)
            else { continue }
            out[name] = value
        }
        return out
    }

    /// Whether a header name/value contains a character that must never appear in
    /// one: CR, LF, or NUL (the classic header/response-splitting vectors).
    static func hasHeaderControlChars(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0.value == 0 }
    }

    // MARK: Export / Import

    /// A self-contained snapshot of the whole app: settings + every task with
    /// its full state (progress, status, resume cursor). The JSON counterpart of
    /// the locator-only text export in the File menu.
    public func exportEnvelope() throws -> Data {
        let envelope = AppExport(settings: Self.exportSanitizedSettings(settings), tasks: tasks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(envelope)
    }

    /// Settings with secrets stripped for a shareable/portable export. A backup
    /// file may be synced, attached to a bug report, or moved between machines, so
    /// the full-authority bearer token and the password hash must not travel in it
    /// (``importEnvelope(_:)`` already refuses to *adopt* them; this stops them
    /// leaving in the first place). The recipient sets their own on import.
    static func exportSanitizedSettings(_ s: AppSettings) -> AppSettings {
        var out = s
        out.remoteToken = ""
        out.remotePasswordHash = ""
        return out
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
        // ffmpeg path is an executable we run on demand — never adopt one from an
        // imported backup (it would be a code-execution vector).
        safe.ffmpegPath = current.ffmpegPath
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
        // Per-file priority is an engine capability; engines that don't honour it
        // simply don't conform to FilePrioritizing (the intentional `as?` replaces
        // the old per-engine no-ops). The model is updated regardless.
        await (engine(for: task.source) as? FilePrioritizing)?.setFilePriority(priority, fileID: fileID, task: id)
        if let i = index(of: id) {
            if let f = tasks[i].files.firstIndex(where: { $0.id == fileID }) {
                tasks[i].files[f].priority = priority
            }
            // The user has now taken explicit control of this file, so drop it from
            // the one-shot add-time skip set — otherwise a later resume/relaunch
            // would silently re-skip a file the user just re-enabled.
            tasks[i].initialSkipFileIDs?.removeAll { $0 == fileID }
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
