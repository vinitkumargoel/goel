import Foundation

/// The scheduler actor (public contract ``DownloadQueue``): one ordered ``DownloadTask`` list routed to
/// engines by `source.kind`, folding their events into snapshots and enforcing ``TrafficProfile`` caps.
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

    /// The unified, ordered task list — the single source of truth. `internal` so the `+Persistence` /
    /// `+SideEffects` sibling extensions can read it; only this file mutates it.
    var tasks: [DownloadTask] = []

    /// O(1) id → index into ``tasks``. Kept in sync by ``appendTask`` /
    /// ``removeTask(at:)`` / ``rebuildTaskIndex()``.
    var taskIndex: [UUID: Int] = [:]

    /// O(1) ``DownloadSource/dedupKey`` → task id. Kept in sync with the list.
    var dedupIndex: [String: UUID] = [:]

    /// The **effective** user configuration: ``storedSettings`` with the managed (MDM) overlay applied.
    /// Everything in the engine/scheduler reads it, so a forced key can't be bypassed by a forgetful path.
    var settings: AppSettings

    /// The settings the *user* chose, exactly as edited — and the only thing ever persisted. Keeping it
    /// separate makes a configuration profile reversible: remove the profile, their own choice comes back.
    var storedSettings: AppSettings

    /// The managed-preferences overlay in force. Re-read on app re-activation (``refreshManagedPolicy()``)
    /// because a profile can be installed while the app is running.
    var managedPolicy: ManagedPolicy

    /// Append-only compliance log. A no-op while `auditLogEnabled` is false,
    /// which is the default — see the file header on ``AuditLog``.
    let auditLog = AuditLog()

    /// Optional on-disk store: when present the queue and settings survive quit & relaunch. Writes are
    /// dispatched off the actor so disk I/O never blocks queue bookkeeping (or the main actor).
    let store: PersistenceStore?

    /// Tasks occupying a download slot: handed to an engine and still `.requestingMetadata`/`.downloading`.
    /// A task leaves on pause/fail/complete/seed, which is when a queued task may be promoted.
    var runningSlots: Set<UUID> = []

    /// Tasks that have been `add`-ed to their engine at least once. Distinguishes
    /// a fresh start (`engine.add`) from a resume (`engine.resume`).
    var engineStarted: Set<UUID> = []

    /// Per-task event-stream consumers.
    var consumers: [UUID: Task<Void, Never>] = [:]

    /// Pending auto-retry timers: one per failed task waiting out its backoff (``AppSettings/autoRetryEnabled``).
    /// Cancelled if the task is removed, manually retried, or resumed in the meantime.
    var autoRetryTasks: [UUID: Task<Void, Never>] = [:]

    /// Auto-retry backoff shape: `base · 2^(attempt-1)`, capped. Mirrors the
    /// HTTP engine's per-request backoff so the two feel consistent.
    static let autoRetryBaseDelay: TimeInterval = 2
    static let autoRetryMaxBackoff: TimeInterval = 60

    /// Snapshot observers.
    private var observers: [UUID: AsyncStream<[DownloadTask]>.Continuation] = [:]

    // MARK: Side-effect services

    // Injected behind narrow `Sendable` ports (`Ports/PlatformPorts.swift`) so the decision logic is
    // testable; the inits default to the real adapters (live IOKit / DispatchSource / Process).

    /// Holds (at most one) "prevent idle sleep" assertion while transfers run, and
    /// reports the power source.
    let power: any PowerControlling

    /// Watches the configured folder for dropped `.torrent` files.
    let folderWatch: any FolderWatching

    /// Screens completed files with the configured external antivirus.
    let scanner: any FileScanning

    /// The periodic backup loop, when ``AppSettings/backupEnabled`` is on.
    var backupTask: Task<Void, Never>?

    /// The periodic filesystem-reconciliation loop: drops completed downloads
    /// whose payload the user has deleted or moved (see `+FileReconcile`).
    var fileReconcileTask: Task<Void, Never>?

    // MARK: Download-window scheduling state

    /// The minute-resolution loop evaluating the time-of-day download window.
    var scheduleTask: Task<Void, Never>?

    /// Whether the download window is currently open. `true` whenever
    /// scheduling is disabled — the scheduler gates promotion on this.
    var scheduleWindowOpen = true

    /// Consolidated automation memory (window/network paused-id ledgers, pre-window profile, RSS seen-keys)
    /// that ``AutomationCore`` reads and hands back each tick — replaces five ledgers that could drift.
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

    /// True when the system default route is a VPN interface. Multi-path physical
    /// binds are refused unless ``AppSettings/aggregationAllowOutsideVPN``.
    var vpnDefaultRouteActive = false

    // MARK: Statistics state

    /// Lifetime/per-day transfer accounting, fed from progress deltas and
    /// persisted (throttled) alongside the settings.
    var stats = TransferStats()

    /// The last time ``stats`` was flushed to disk (flushes are throttled to
    /// ~30 s; status transitions flush immediately).
    var lastStatsFlush = Date.distantPast

    /// Per-task byte counts already folded into ``stats``, kept apart from the task's own counters so a
    /// restart below the previous absolute count re-bases instead of losing the interval (``StatsAccumulator``).
    typealias StatsMark = StatsAccumulator.Mark
    var statsMarks: [UUID: StatsMark] = [:]

    /// Sliding-window meters behind the displayed ↓/↑ rates: the task stores the windowed average, never
    /// the engine's raw 100–200 ms rate (``SpeedMeter``). Dropped on leaving transfer so resume ramps fresh.
    var speedMeters: [UUID: SpeedMeter] = [:]

    // MARK: Persistence pipeline

    /// Serial on-disk writer (nil when there is no store). Behaviour façade lives in
    /// `DownloadManager+Persistence.swift`; `internal` so that file can enqueue / drain it.
    let pipeline: PersistencePipeline?

    /// Bridges detached-writer failures back onto this actor's
    /// ``notePersistenceError``. Installed after `self` is fully formed.
    let persistErrorHandler: PersistenceErrorHandler?

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
        // The overlay is resolved here so the first read of `settings`, before any restore, already
        // reflects MDM policy; both rows are clamped as ``adoptStoredSettings(_:)`` does.
        let policy = ManagedPolicy.current()
        self.managedPolicy = policy
        let stored = settings.validated()
        self.storedSettings = stored
        self.settings = policy.apply(to: stored).validated()
        self.store = store
        self.power = power
        self.folderWatch = folderWatch
        self.scanner = scanner
        if let store {
            let handler = PersistenceErrorHandler()
            self.persistErrorHandler = handler
            self.pipeline = PersistencePipeline(store: store, errorHandler: handler)
        } else {
            self.persistErrorHandler = nil
            self.pipeline = nil
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
        // The overlay is resolved here so the first read of `settings`, before any restore, already
        // reflects MDM policy; both rows are clamped as ``adoptStoredSettings(_:)`` does.
        let policy = ManagedPolicy.current()
        self.managedPolicy = policy
        let stored = settings.validated()
        self.storedSettings = stored
        self.settings = policy.apply(to: stored).validated()
        self.store = store
        self.power = power
        self.folderWatch = folderWatch
        self.scanner = scanner
        if let store {
            let handler = PersistenceErrorHandler()
            self.persistErrorHandler = handler
            self.pipeline = PersistencePipeline(store: store, errorHandler: handler)
        } else {
            self.persistErrorHandler = nil
            self.pipeline = nil
        }
    }


    // MARK: Persistence

    /// Restore queue + settings from ``store``. Call once after construction: mid-flight and seeding tasks
    /// come back `.paused` (nothing runs an engine, so "Seeding" would be a lie); terminal ones keep state.
    public func restore() async {
        guard let store else { return }
        installPersistErrorBridge()

        do {
            let saved = try store.loadSettings()
            // Adopt unconditionally, even when `loadSettings()` returns nil: ``adoptStoredSettings(_:)``
            // is the only thing that configures ``auditLog``; skipping it silently ignored forced policy.
            adoptStoredSettings(saved ?? storedSettings)
        } catch {
            notePersistenceError(error)
            adoptStoredSettings(storedSettings)
        }

        do {
            if let savedStats = try store.loadStats() { stats = savedStats }
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
            GoelLog.persistence.error("Restore failed", .detail(String(describing: error)))
            publish()
            return
        }

        tasks = loaded.map(Self.normalizeRestored)
        rebuildTaskIndex()

        // Drop completed downloads whose file was deleted/moved while the app was closed, before the row
        // can flash in the list (pruned tasks leave disk here; survivors are persisted just below).
        pruneMissingCompletedFiles()

        // Reflect any status normalisation back to disk.
        for task in tasks { persist(task) }
        await applyEngineConfigs()
        await updateWatchFolder()
        updateBackupSchedule()
        updateDownloadSchedule()
        updateRSSSchedule()
        updateRedownloadSchedule()
        startFileReconcile()
        armScheduledStarts()
        updatePowerAssertion()
        publish()
    }

    /// A human-readable persistence problem surfaced to the UI — a failed write means the queue silently
    /// diverges from disk. `internal` so `notePersistenceError` (in `+Persistence`) can set it.
    var persistenceWarning: String?


    /// Wire the detached writer back to ``notePersistenceError``. Safe to call
    /// repeatedly; no-ops once installed or when there is no store.
    func installPersistErrorBridge() {
        guard let handler = persistErrorHandler else { return }
        handler.install { [weak self] error in
            await self?.notePersistenceError(error)
        }
    }

    // The persistence pipeline's behaviour (currentPersistenceWarning, notePersistenceError, persist,
    // persistSettings, persistRemoval) lives in `DownloadManager+Persistence.swift`.

    // MARK: Observation

    /// The current task list.
    public var snapshot: [DownloadTask] { tasks }

    /// The current settings.
    public var currentSettings: AppSettings { settings }

    /// The lifetime/per-day transfer statistics.
    public var currentStats: TransferStats { stats }

    // MARK: Download history

    /// The archived completed downloads, newest first. Reads the store directly, so an entry archived a
    /// moment ago may trail the serial write pipeline by one flush — fine for a browsing UI.
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
        guard let i = index(of: id) else { return nil }
        return tasks[i]
    }

    /// A live stream of task-list snapshots. The current list is delivered
    /// immediately on subscription, then again after every change.
    public func updates() -> AsyncStream<[DownloadTask]> {
        let (stream, continuation) = AsyncStream<[DownloadTask]>.makeStream(bufferingPolicy: .unbounded)
        let key = UUID()
        observers[key] = continuation
        continuation.yield(tasks)
        continuation.onTermination = { [weak self] _ in
            // Bound before the `Task` like the watch-folder callback in `+SideEffects`: the capture list
            // makes `self` a var, and CI's toolchain refuses to read one from concurrent code.
            guard let self else { return }
            Task { await self.removeObserver(key) }
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

    /// Throttle progress-driven snapshots to ~10 Hz. Structural/status changes still publish immediately
    /// via ``publish()``; only `.progress`/`.fileProgress` is coalesced, so the UI isn't flooded.
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

    /// Add a download, de-duplicated on ``DownloadSource/dedupKey`` (the existing task is returned) with the
    /// folder from ``AppSettings/defaultFolderRule``. `startPaused` skips the scheduler: race-free hold.
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
        deselectedFileIDs: [Int]? = nil,
        // A browser capture already holds its session; riding along on the create avoids a first request
        // going out signed-out. Sanitised below and never stored — see ``DownloadTask/cookieHeader``.
        cookieHeader: String? = nil,
        cookieSource: CookieSource? = nil,
        cookieHost: String? = nil,
        /// Which interface(s) this download egresses. nil = the server-wide policy.
        network: NetworkSelection? = nil
    ) -> DownloadTask {
        if let existingID = dedupIndex[source.dedupKey],
           let i = index(of: existingID) {
            return tasks[i]
        }
        // A future start time implies "hold it until then" — same race-free
        // create-paused path as `startPaused`.
        let holdPaused = startPaused || scheduledAt != nil
        let directory = saveDirectory ?? defaultDirectory(for: source)
        // Resolve the on-disk name conflict at creation only — resume/retry reuse the stored name and the
        // partial file's path. HTTP only (torrent names are placeholders); caller names are sanitized.
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
        // Sanitised once here so a malformed capture becomes "no cookies" rather
        // than a header that could split the request.
        let cleanedCookie = cookieHeader.flatMap(CookieHeader.sanitized)
        let task = DownloadTask(
            source: source,
            name: name,
            saveDirectory: directory,
            // Seed the size/file list already resolved on the add screen so the task appears fully-formed
            // instead of re-showing "gathering"; the engine still reconciles from truth as it runs.
            totalBytes: totalBytes,
            status: holdPaused ? .paused : .queued,
            priority: priority,
            files: files,
            expectedChecksum: expectedChecksum,
            scheduledAt: scheduledAt,
            mirrors: Self.sanitizedMirrors(mirrors, primary: source),
            cookieHeader: cleanedCookie,
            cookieSource: cleanedCookie == nil ? CookieSource.none : (cookieSource ?? .browser),
            // nil scope is not "no scope" — ``DownloadTask/sendsCookies(to:)`` falls back to the task's
            // own origin, which is what a capture for this exact URL means.
            cookieHost: cleanedCookie == nil ? nil : cookieHost,
            initialSkipFileIDs: (deselectedFileIDs?.isEmpty ?? true) ? nil : deselectedFileIDs,
            // `.auto` is the default in every other spelling; store nil so old and
            // new tasks compare and serialise identically.
            networkSelection: network == .auto ? nil : network
        )
        appendTask(task)
        persist(task)
        recordAudit(.added, task: task)
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

    /// Resolve a source's metadata for the add-confirmation screen *without* queueing anything. Always
    /// returns a preview — on failure a `note` plus the best-effort name, so the user can still start.
    public func resolveMetadata(for source: DownloadSource, saveDirectory: String? = nil) async -> DownloadPreview {
        let directory = saveDirectory ?? defaultDirectory(for: source)
        let fallbackName = Self.defaultName(for: source)
        let kind = source.kind
        let engine = engine(for: source)

        // The seam: ask the engine to resolve, never downcasting to a concrete type; the manager folds
        // what it reports into the preview, applying its own fallback name and kind-specific note.
        guard let meta = await engine.resolveMetadata(for: source, in: directory) else {
            // Nil means it couldn't resolve now (unreachable / no peers) or doesn't probe at all. Only an
            // engine ADVERTISING metadata resolution earns a note; otherwise it's a best-effort name.
            let note = engine.capabilities.contains(.resolvesMetadata) ? Self.unresolvedNote(for: kind) : nil
            return DownloadPreview(
                source: source, suggestedName: fallbackName, totalBytes: nil,
                isEstimatedSize: kind == .hls, kind: kind, note: note)
        }

        let name = meta.name.isEmpty ? fallbackName : meta.name
        return DownloadPreview(
            source: source, suggestedName: name, totalBytes: meta.totalBytes,
            isEstimatedSize: meta.isEstimatedSize, files: meta.files, kind: kind,
            // An engine that knows *why* it failed says so; the generic note is
            // the fallback, not an override.
            note: meta.reachable ? nil : (meta.failureNote ?? Self.unresolvedNote(for: kind)),
            suggestedChecksum: meta.suggestedChecksum)
    }

    /// The non-fatal note shown when metadata couldn't be resolved up front. Kind-specific so the wording
    /// matches the failure mode; the user can always still start the download.
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

    /// Pause a task (queued or active). Frees its slot so a queued task can run.
    public func pause(_ id: DownloadTask.ID) async {
        guard await pauseTask(id) else { return }
        publish()
        schedule()
    }

    /// Pause bookkeeping *without* the trailing snapshot/scheduler pass, so ``pauseAll()`` pays for both
    /// once: per-task it is quadratic, and it would let ``schedule()`` refill a slot being reclaimed.
    private func pauseTask(_ id: DownloadTask.ID) async -> Bool {
        guard let task = task(id) else { return false }
        guard task.status != .paused, !task.status.isTerminal else { return false }

        if engineStarted.contains(id) {
            await engine(for: task.source).pause(id)
        }
        runningSlots.remove(id)
        // Re-validate after the await: the task may have completed or failed while
        // the actor was suspended — never clobber a terminal state with `.paused`.
        guard let i = index(of: id), !tasks[i].status.isTerminal else {
            updatePowerAssertion()
            return true
        }
        tasks[i].status = .paused
        tasks[i].connections = nil
        clearLiveRates(id)
        persist(tasks[i])
        updatePowerAssertion()
        return true
    }

    /// Resume a paused task. It re-enters the queue and is promoted subject to
    /// the simultaneous-download cap.
    public func resume(_ id: DownloadTask.ID) async {
        guard resumeTask(id) else { return }
        publish()
        schedule()
    }

    /// Resume bookkeeping without the trailing snapshot/scheduler pass — counterpart of ``pauseTask(_:)``,
    /// same reason. Returns whether the task was actually paused and has now been re-queued.
    private func resumeTask(_ id: DownloadTask.ID) -> Bool {
        guard let i = index(of: id), tasks[i].status == .paused else { return false }
        tasks[i].status = .queued
        tasks[i].scheduledAt = nil   // starting now supersedes any scheduled start
        persist(tasks[i])
        return true
    }

    /// Retry a failed task: clear the error and re-queue it, keeping partial bytes / resume cursor so it
    /// continues, then let the scheduler promote it. A no-op unless the task is currently `.failed`.
    public func retry(_ id: DownloadTask.ID) async {
        guard let i = index(of: id), case .failed = tasks[i].status else { return }
        // A deliberate manual retry supersedes any armed auto-retry and restarts
        // the auto-retry budget from scratch.
        autoRetryTasks[id]?.cancel()
        autoRetryTasks[id] = nil
        tasks[i].status = .queued
        tasks[i].scanVerdict = nil
        tasks[i].scheduledAt = nil
        tasks[i].retryAttempt = nil
        clearLiveRates(id)
        persist(tasks[i])
        publish()
        schedule()
    }

    /// Arm an automatic retry for a just-failed task when ``AppSettings/autoRetryEnabled`` is on and the
    /// budget isn't spent: bumps ``DownloadTask/retryAttempt``, re-queues after an exponential backoff.
    func scheduleAutoRetryIfNeeded(_ id: DownloadTask.ID) {
        guard settings.autoRetryEnabled, settings.autoRetryMaxAttempts > 0 else { return }
        guard let i = index(of: id), case .failed = tasks[i].status else { return }
        let attempt = tasks[i].retryAttempt ?? 0
        guard attempt < settings.autoRetryMaxAttempts else { return }
        let next = attempt + 1
        tasks[i].retryAttempt = next
        persist(tasks[i])
        let delay = min(Self.autoRetryMaxBackoff, Self.autoRetryBaseDelay * pow(2, Double(next - 1)))
        autoRetryTasks[id]?.cancel()
        autoRetryTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performAutoRetry(id)
        }
    }

    /// Fire a scheduled auto-retry once its backoff elapses, but only if the task is *still* failed —
    /// the user may have removed, resumed, or manually retried it while the timer waited.
    private func performAutoRetry(_ id: DownloadTask.ID) async {
        autoRetryTasks[id] = nil
        guard let i = index(of: id), case .failed = tasks[i].status else { return }
        tasks[i].status = .queued
        tasks[i].scanVerdict = nil
        tasks[i].scheduledAt = nil
        clearLiveRates(id)
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
        clearLocalState(id, removeFromList: true)
        persistRemoval(id)
        updatePowerAssertion()
        publish()
        schedule()
    }

    /// Tear down all live subscriptions, observers and side-effect services. Call
    /// before releasing the manager so nothing is left dangling.
    public func shutdown() async {
        for consumer in consumers.values { consumer.cancel() }
        consumers.removeAll()
        for retry in autoRetryTasks.values { retry.cancel() }
        autoRetryTasks.removeAll()
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
        fileReconcileTask?.cancel()
        fileReconcileTask = nil
        let folderWatch = self.folderWatch
        await folderWatch.stop()
        power.setPreventSleep(false)
        // Flush the stats then drain every queued write before returning.
        persistStats(force: true)
        await pipeline?.shutdown()
    }

    /// Pause every queued or active task. One snapshot and one scheduler pass for
    /// the whole batch — see ``pauseTask(_:)``.
    public func pauseAll() async {
        let ids = tasks
            .filter { $0.status.isActive || $0.status == .queued }
            .map(\.id)
        var changed = false
        for id in ids {
            if await pauseTask(id) { changed = true }
        }
        guard changed else { return }
        publish()
        schedule()
    }

    /// Resume every paused task with one snapshot and one scheduler pass, so ``schedule()`` promotes up
    /// to the simultaneous cap in strict priority order rather than first-resumed-first-served.
    public func resumeAll() async {
        let ids = tasks.filter { $0.status == .paused }.map(\.id)
        var changed = false
        for id in ids {
            if resumeTask(id) { changed = true }
        }
        guard changed else { return }
        publish()
        schedule()
    }

    /// Apply a settings change in one call and return the **effective** result. The copy is seeded from
    /// ``storedSettings``, never the overlaid ``settings``, or forced MDM keys would outlive their profile.
    @discardableResult
    public func apply(_ change: @Sendable (inout AppSettings) -> Void) async -> AppSettings {
        var copy = storedSettings
        change(&copy)
        await updateSettings(copy)
        return settings
    }

    /// Switch the active traffic profile via ``apply(_:)``, so new limits reach both engines and the
    /// scheduler re-runs (the simultaneous cap may have changed). Returns the committed settings.
    @discardableResult
    public func setProfile(_ name: String) async -> AppSettings {
        await apply { $0.selectedProfileName = name }
    }

    /// Toggle the "snail" speed limit (disabled = unlimited). Delegates to ``apply(_:)`` so both engines
    /// are re-applied live, and returns the committed settings.
    @discardableResult
    public func setSpeedLimitEnabled(_ enabled: Bool) async -> AppSettings {
        await apply { $0.speedLimitEnabled = enabled }
    }

    /// Change the default save folder, returning the committed settings. ``add`` reads the rule live, so
    /// this only persists/publishes — no ``updateSettings`` cascade re-arming timers on a folder change.
    @discardableResult
    public func setDefaultSaveDirectory(_ path: String) async -> AppSettings {
        var updated = storedSettings
        updated.defaultSaveDirectory = path
        adoptStoredSettings(updated)
        persistSettings()
        publish()
        return settings
    }

    // MARK: Audit

    /// Append one task transition to the compliance log, fire-and-forget: the log records the queue and
    /// never gates it, so a slow audit directory can't stall a download. ``AuditEvent`` applies redaction.
    func recordAudit(_ action: AuditEvent.Action, task: DownloadTask) {
        guard settings.auditLogEnabled else { return }
        Task { [auditLog] in await auditLog.record(action, task: task) }
    }

    /// The directory the audit log is writing to, or nil when logging is off.
    public func auditLogDirectory() async -> URL? {
        await auditLog.currentDirectory()
    }

    // MARK: Managed policy

    /// The one funnel for writing ``storedSettings``: recomputes the effective row through the overlay,
    /// re-configures ``auditLog``, and validates *after* the overlay so forced values can't skip a clamp.
    func adoptStoredSettings(_ newSettings: AppSettings) {
        storedSettings = newSettings.validated()
        settings = managedPolicy.apply(to: storedSettings).validated()
        let auditConfiguration = AuditLog.Configuration(settings: settings)
        Task { [auditLog] in await auditLog.configure(auditConfiguration) }
    }

    /// Re-read the managed-preferences overlay and re-apply it. Call on app re-activation: a launch-only
    /// policy would be one the user could dodge by never quitting.
    public func refreshManagedPolicy() async {
        let policy = ManagedPolicy.current()
        guard policy != managedPolicy else { return }
        managedPolicy = policy
        // Re-run the full cascade: a forced bandwidth cap or folder rule has to
        // reach the engines, not just the struct.
        await updateSettings(storedSettings)
    }

    /// The managed overlay currently in force, for UI that needs to disable and
    /// annotate the controls an administrator has locked.
    public func currentManagedPolicy() -> ManagedPolicy { managedPolicy }

    /// Replace the settings object and re-apply every dependent subsystem (engine limits, network/session
    /// config, power, watch-folder, backup, scheduler). The default-folder rule is read live by ``add``.
    public func updateSettings(_ newSettings: AppSettings) async {
        adoptStoredSettings(newSettings)
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
        // Only torrent engines control piece order; the capability query replaces the old base-protocol
        // no-op. The model flag is set regardless — it drives the streamability check.
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
        _ = mutateTask(id) {
            $0.speedLimitBytesPerSec = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
        }
    }

    /// Cap one torrent's upload rate in bytes/sec (nil/0 = uncapped), applied live.
    public func setTaskUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.setUploadLimit(bytesPerSec, task: id)
        // Re-resolve the index AFTER the actor hop: `tasks` may have been mutated (concurrent remove)
        // while suspended, so a pre-await index could now point past the end or at a different task.
        if let i = index(of: id) {
            tasks[i].uploadLimitBytesPerSec = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
            persist(tasks[i])
        }
        publish()
    }

    /// Set a per-torrent seed-ratio limit; reaching it stops and completes the torrent. nil restores the
    /// profile's global limit, an explicit 0 means "seed indefinitely" and overrides the profile.
    public func setSeedRatioLimit(_ ratio: Double?, task id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.setSeedRatioLimit(ratio, task: id)
        // Re-resolve the index after the actor hop (see setTaskUploadLimit).
        if let i = index(of: id) {
            tasks[i].seedRatioLimit = ratio
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
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = mutateTask(id) {
            $0.label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// Replace a task's tag set (trimmed, de-duped case-insensitively, order-stable).
    public func setTags(_ tags: [String], task id: DownloadTask.ID) async {
        let cleaned = Self.normalizeTags(tags)
        _ = mutateTask(id) {
            $0.tags = cleaned.isEmpty ? nil : cleaned
        }
    }

    /// Set (or clear, with nil/empty) a free-form note on a task.
    public func setNote(_ note: String?, task id: DownloadTask.ID) async {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = mutateTask(id) {
            $0.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// Set the per-task `Referer` and extra request headers (HTTP). Reserved/malformed names are dropped,
    /// nil/empty clears each field; returns the ignored reserved names so the UI can tell the user.
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
        // Names the user supplied that we refused to store — reserved only; control-char/empty are
        // malformed rather than "reserved", and reporting them as such is more confusing than useful.
        return raw.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { Self.reservedHeaderNames.contains($0) }
            .sorted()
    }

    /// Attach (or clear with nil) a task's browser session cookies: sanitised via ``CookieHeader`` and kept
    /// in memory only (excluded from `Codable`). The non-secret `cookieSource`/`cookieHost` is persisted.
    public func setCookies(_ raw: String?, host: String?, source: CookieSource,
                           task id: DownloadTask.ID) async {
        guard let i = index(of: id) else { return }
        let cleaned = raw.flatMap(CookieHeader.sanitized)
        tasks[i].cookieHeader = cleaned
        tasks[i].cookieSource = cleaned == nil ? CookieSource.none : source
        tasks[i].cookieHost = cleaned == nil ? nil : (host ?? tasks[i].sourceHost)
        persist(tasks[i])
        publish()
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

    /// Rename a download's file and display name, never clobbering an existing one (appends ` (n)`). Not
    /// for torrents (libtorrent owns their layout) or active transfers (the writer holds the old path).
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
        "proxy-connection",
        // `cookie` is reserved because the plaintext headers editor persists into SQLite and the shareable
        // JSON export — a session cookie must never travel that way. Use ``setCookies(_:host:source:task:)``.
        "cookie"
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

    /// A self-contained snapshot of the whole app: settings + every task with full state (progress,
    /// status, resume cursor). The JSON counterpart of the locator-only text export in the File menu.
    public func exportEnvelope() throws -> Data {
        let envelope = AppExport(settings: Self.exportSanitizedSettings(settings), tasks: tasks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(envelope)
    }

    /// Settings with secrets stripped for export: a backup may be synced or attached to a bug report, so
    /// the bearer token and password hash must not travel in it (``importEnvelope(_:)`` won't adopt them).
    static func exportSanitizedSettings(_ s: AppSettings) -> AppSettings {
        var out = s
        out.remoteToken = ""
        out.remotePasswordHash = ""
        return out
    }

    /// Import an ``exportEnvelope()`` snapshot: merge its tasks (skipping known sources), all `.paused`.
    /// A backup is untrusted: settings that run code, open a port, redirect traffic or move files are never adopted.
    @discardableResult
    public func importEnvelope(_ data: Data) async throws -> Int {
        let envelope = try JSONDecoder().decode(AppExport.self, from: data)
        var added = 0
        for imported in envelope.tasks {
            let task = PersistenceStore.sanitizedForImport(imported)
            // An envelope is untrusted: two entries may carry the SAME task id. `taskIndex` keys on it,
            // so the loser becomes an unreachable zombie row — refuse the duplicate here instead.
            guard index(of: task.id) == nil else { continue }
            guard dedupIndex[task.source.dedupKey] == nil else { continue }
            let t = Self.normalizeRestored(task)
            appendTask(t)
            persist(t)
            added += 1
        }
        // `storedSettings`, not `settings`: security-sensitive fields come from the user's OWN row, since
        // persisting the overlaid one would freeze an admin's forced keys in and outlive the profile.
        await updateSettings(Self.sanitizedImportedSettings(envelope.settings, current: storedSettings))
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
        // Network listeners: the WHOLE `remote*` family is forced back, not just the on/off switch —
        // credentials, auth policy and proxy trust (`0.0.0.0/0` trusts everyone) each hand over a portal.
        safe.remoteAccessEnabled = current.remoteAccessEnabled
        safe.remotePort = current.remotePort
        safe.remoteToken = current.remoteToken
        safe.remoteAllowLAN = current.remoteAllowLAN
        safe.remoteRequireAuth = current.remoteRequireAuth
        safe.remoteUsername = current.remoteUsername
        safe.remotePasswordHash = current.remotePasswordHash
        safe.remoteReadOnly = current.remoteReadOnly
        safe.remoteSessionMinutes = current.remoteSessionMinutes
        safe.remoteTLSEnabled = current.remoteTLSEnabled
        safe.remoteTLSIdentityPath = current.remoteTLSIdentityPath
        safe.remoteLoginMaxAttempts = current.remoteLoginMaxAttempts
        safe.remoteLoginBackoffSeconds = current.remoteLoginBackoffSeconds
        safe.remoteTrustedHeaderAuthEnabled = current.remoteTrustedHeaderAuthEnabled
        safe.remoteTrustedHeaderName = current.remoteTrustedHeaderName
        safe.remoteTrustedProxies = current.remoteTrustedProxies
        // Traffic interception: a proxy adopted from a file would route every connection — URLs, `Cookie`
        // headers, Basic-auth — through a host its author chose, and could swap any plain-HTTP payload.
        safe.proxyMode = current.proxyMode
        safe.proxyType = current.proxyType
        safe.proxyHost = current.proxyHost
        safe.proxyPort = current.proxyPort
        safe.proxyAllProtocols = current.proxyAllProtocols
        // Filesystem reach: the default save folder is also the containment root the remote portal
        // validates every requested path against, and the audit directory holds the compliance record.
        safe.defaultSaveDirectory = current.defaultSaveDirectory
        safe.auditLogDirectory = current.auditLogDirectory
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
        // Per-file priority is an engine capability: engines that don't honour it don't conform to
        // FilePrioritizing (the `as?` replaces the old per-engine no-ops). The model updates regardless.
        await (engine(for: task.source) as? FilePrioritizing)?.setFilePriority(priority, fileID: fileID, task: id)
        if let i = index(of: id) {
            if let f = tasks[i].files.firstIndex(where: { $0.id == fileID }) {
                tasks[i].files[f].priority = priority
            }
            // The user has taken explicit control of this file, so drop it from the one-shot add-time
            // skip set — otherwise a later resume/relaunch would silently re-skip what they re-enabled.
            tasks[i].initialSkipFileIDs?.removeAll { $0 == fileID }
            persist(tasks[i])
        }
        publish()
    }

    // Engine limits/config (applyLimits, applyEngineConfigs, reapplyHTTPBudget)
    // live in `DownloadManager+EngineConfig.swift`.

    // MARK: Default-folder rule

    /// Resolve a new download's save directory from ``AppSettings/defaultFolderRule``, with
    /// ``AppSettings/defaultSaveDirectory`` as the base/fixed folder.
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

    // Side effects (power, watch folder, backup, post-completion hooks) live in `+SideEffects.swift`;
    // queue promotion in `+Scheduling.swift`; engine-event folding in `+Events.swift`.

    // MARK: Helpers

    /// `internal` so the `+Scheduling` / `+Events` extensions can locate a task.
    func index(of id: UUID) -> Int? {
        if let i = taskIndex[id], i < tasks.count, tasks[i].id == id { return i }
        // Stale map (should be rare) — rebuild once.
        rebuildTaskIndex()
        return taskIndex[id]
    }

    /// Rebuild ``taskIndex``/``dedupIndex`` from ``tasks`` after a bulk replace. First-wins explicit loop,
    /// never `Dictionary(uniqueKeysWithValues:)`: a legacy duplicate `dedupKey` would trap on every launch.
    func rebuildTaskIndex() {
        taskIndex.removeAll(keepingCapacity: true)
        dedupIndex.removeAll(keepingCapacity: true)
        for (offset, task) in tasks.enumerated() {
            taskIndex[task.id] = offset
            let key = task.source.dedupKey
            if dedupIndex[key] == nil { dedupIndex[key] = task.id }
        }
    }

    /// Append and keep the index maps current.
    func appendTask(_ task: DownloadTask) {
        taskIndex[task.id] = tasks.count
        dedupIndex[task.source.dedupKey] = task.id
        tasks.append(task)
    }

    /// Remove at a known index and shift subsequent index entries.
    func removeTask(at i: Int) {
        let removed = tasks[i]
        let key = removed.source.dedupKey
        tasks.remove(at: i)
        taskIndex[removed.id] = nil
        if dedupIndex[key] == removed.id {
            // A legacy queue can hold a second task under the same key — hand the entry to the survivor
            // rather than leaving it unindexed, which would let the duplicate be added a third time.
            dedupIndex[key] = tasks.first { $0.source.dedupKey == key }?.id
        }
        for j in i..<tasks.count {
            taskIndex[tasks[j].id] = j
        }
    }

    /// Mid-flight → `.paused`, zero live rates. Shared by restore and import.
    static func normalizeRestored(_ task: DownloadTask) -> DownloadTask {
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
        return t
    }

    /// Drop per-task bookkeeping (and optionally the list row). Does not touch
    /// disk or engines — callers that need those do them around this.
    func clearLocalState(_ id: UUID, removeFromList: Bool) {
        autoRetryTasks[id]?.cancel()
        autoRetryTasks[id] = nil
        consumers[id]?.cancel()
        consumers[id] = nil
        runningSlots.remove(id)
        engineStarted.remove(id)
        statsMarks[id] = nil
        speedMeters[id] = nil
        if removeFromList, let i = index(of: id) {
            removeTask(at: i)
        }
    }

    /// Zero live rates and drop the speed meter (pause / fail / retry).
    func clearLiveRates(_ id: UUID) {
        if let i = index(of: id) {
            tasks[i].downloadSpeed = 0
            tasks[i].uploadSpeed = 0
        }
        speedMeters[id] = nil
    }

    /// Mutate one task, persist, optionally publish. Returns false if missing.
    @discardableResult
    func mutateTask(_ id: UUID, publishAfter: Bool = true,
                    _ body: (inout DownloadTask) -> Void) -> Bool {
        guard let i = index(of: id) else { return false }
        body(&tasks[i])
        persist(tasks[i])
        if publishAfter { publish() }
        return true
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
