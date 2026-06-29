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

    private let httpEngine: any DownloadEngine
    private let torrentEngine: any DownloadEngine
    private let hlsEngine: any DownloadEngine

    // MARK: State

    /// The unified, ordered task list. The single source of truth.
    private var tasks: [DownloadTask] = []

    /// User configuration (active profile, snail flag, default folder, plus the
    /// General/Network/BitTorrent/Notification/Power/Backup/Antivirus panes).
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

    // MARK: Side-effect services

    /// Holds (at most one) "prevent idle sleep" assertion while transfers run.
    private let powerManager = PowerManager()

    /// Watches the configured folder for dropped `.torrent` files.
    private let watchFolder = WatchFolderMonitor()

    /// The periodic backup loop, when ``AppSettings/backupEnabled`` is on.
    private var backupTask: Task<Void, Never>?

    // MARK: Persistence pipeline

    /// A single on-disk mutation, funnelled through the serial ``persistContinuation``.
    private enum PersistOp: Sendable {
        case saveTask(DownloadTask)
        case deleteTask(UUID)
        case saveSettings(AppSettings)
    }

    /// The (one-shot) source of the serial persistence stream, consumed the first
    /// time a write is enqueued. `nil` once started, or when there is no store.
    private var persistStream: AsyncStream<PersistOp>?

    /// The write side of the serial persistence pipeline.
    private var persistContinuation: AsyncStream<PersistOp>.Continuation?

    /// The single worker draining ``persistStream`` in enqueue order.
    private var persistWorker: Task<Void, Never>?

    /// Whether ``persistWorker`` has been started.
    private var persistStarted = false

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
    private var persistenceWarning: String?

    /// The latest persistence warning, if any. Polled by the UI bridge.
    public var currentPersistenceWarning: String? { persistenceWarning }

    /// Record (and log) a persistence failure so it can be surfaced.
    private func notePersistenceError(_ error: Error) {
        persistenceWarning = "Couldn’t save to disk: \(error.localizedDescription)"
        FileHandle.standardError.write(Data("[GoelDownloader] persistence error: \(error)\n".utf8))
    }

    /// Start the single serial persistence worker the first time it is needed.
    ///
    /// All on-disk mutations flow through one ordered stream so they are applied
    /// strictly in enqueue order. This removes the race where two independent
    /// detached writes reached GRDB's queue in an undefined order and a stale
    /// snapshot landed last — e.g. a `.finished` snapshot (still `.downloading`)
    /// overwriting the authoritative `.completed` write, which would resurface a
    /// finished download as Paused on the next launch.
    private func ensurePersistWorker() {
        guard !persistStarted, let store, let stream = persistStream else { return }
        persistStarted = true
        persistStream = nil
        persistWorker = Task.detached { [weak self] in
            for await op in stream {
                do {
                    switch op {
                    case .saveTask(let task): try store.saveTask(task)
                    case .deleteTask(let id): try store.deleteTask(id)
                    case .saveSettings(let settings): try store.saveSettings(settings)
                    }
                } catch {
                    await self?.notePersistenceError(error)
                }
            }
        }
    }

    /// Persist a single task. Enqueued on the serial pipeline (see
    /// ``ensurePersistWorker()``) so it can never be overtaken by an older write.
    private func persist(_ task: DownloadTask) {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.saveTask(task))
    }

    /// Persist the current settings on the serial pipeline.
    private func persistSettings() {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.saveSettings(settings))
    }

    /// Remove a persisted task on the serial pipeline.
    private func persistRemoval(_ id: DownloadTask.ID) {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.deleteTask(id))
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

    /// Push the current effective profile's bandwidth/connection caps to both
    /// engines. Useful at startup and whenever the profile or snail changes.
    public func applyLimits() async {
        let profile = settings.effectiveProfile
        await httpEngine.applyLimits(profile)
        await torrentEngine.applyLimits(profile)
        await hlsEngine.applyLimits(profile)
    }

    // MARK: Engine configuration

    /// Push limits *and* the network/session configuration derived from the
    /// current settings to both engines. `applyLimits` is part of the
    /// `DownloadEngine` protocol; `applyNetworkConfig` / `applySessionConfig` are
    /// concrete to the production engines, so they apply only when those engines
    /// are in use (a test fake simply skips them).
    private func applyEngineConfigs() async {
        await applyLimits()
        if let http = httpEngine as? HTTPEngine {
            await http.applyNetworkConfig(httpNetworkConfig())
        }
        if let torrent = torrentEngine as? TorrentEngine {
            await torrent.applySessionConfig(torrentSessionConfig())
        }
        if let hls = hlsEngine as? HLSEngine {
            await hls.setMaxHeight(settings.hlsMaxHeight)
        }
    }

    private func httpNetworkConfig() -> HTTPNetworkConfig {
        HTTPNetworkConfig(
            timeout: settings.connectionTimeout,
            retryCount: settings.retryCount,
            retryInterval: settings.retryInterval,
            userAgent: settings.userAgent,
            proxyMode: settings.proxyMode,
            proxyHost: settings.proxyHost,
            proxyPort: settings.proxyPort,
            cookieAuthEnabled: settings.cookieAuthEnabled
        )
    }

    private func torrentSessionConfig() -> TorrentEngine.SessionConfig {
        TorrentEngine.SessionConfig(
            enableDHT: settings.btEnableDHT,
            enableLSD: settings.btEnableLPD,
            enableUTP: settings.btEnableUTP,
            encryptionMode: settings.btEncryptionMode
        )
    }

    /// Re-apply the HTTP engine's per-server connection cap so the *aggregate* of
    /// all concurrently running HTTP downloads stays within the profile's global
    /// `maxConnections`, instead of every download independently claiming the full
    /// per-server fan-out. Best-effort: already-running segment groups keep their
    /// governor; the tighter cap takes effect for subsequently computed segments.
    private func reapplyHTTPBudget() async {
        guard let http = httpEngine as? HTTPEngine else { return }
        var profile = settings.effectiveProfile
        let activeHTTP = tasks.filter { $0.source.kind == .http && $0.status.isActive }.count
        if profile.maxConnections > 0, activeHTTP > 0 {
            let perDownload = max(1, profile.maxConnections / activeHTTP)
            profile.maxConnectionsPerServer = min(profile.maxConnectionsPerServer, perDownload)
        }
        await http.applyLimits(profile)
    }

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

    /// A coarse content category derived from the source's apparent file
    /// extension (torrents bucket together). Mirrors the app's file-type buckets
    /// without importing the app layer.
    private static func categoryFolder(for source: DownloadSource) -> String {
        if source.kind == .torrent { return "Torrents" }
        let name = defaultName(for: source).lowercased()
        func ext(_ list: [String]) -> Bool { list.contains { name.hasSuffix(".\($0)") } }
        if ext(["mkv", "mp4", "avi", "mov", "webm", "m4v", "flv"]) { return "Video" }
        if ext(["mp3", "flac", "wav", "aac", "m4a", "ogg", "opus"]) { return "Audio" }
        if ext(["jpg", "jpeg", "png", "gif", "webp", "heic", "svg"]) { return "Images" }
        if ext(["iso", "dmg", "pkg", "app", "exe", "deb", "msi", "xip"]) { return "Software" }
        if ext(["zip", "gz", "tar", "7z", "rar", "bz2", "xz"]) { return "Archives" }
        if ext(["pdf", "doc", "docx", "txt", "epub", "csv", "xlsx"]) { return "Documents" }
        return "Other"
    }

    // MARK: Power management

    /// Recompute and apply the "prevent idle sleep" assertion from the current
    /// settings and active-download state. Idempotent (see ``PowerManager``).
    private func updatePowerAssertion() {
        powerManager.setPreventSleep(shouldPreventSleep())
    }

    private func shouldPreventSleep() -> Bool {
        guard settings.preventSleepWhileDownloading else { return false }

        var hasActiveDownload = false
        var hasSeeding = false
        for task in tasks {
            switch task.status {
            case .downloading, .verifying, .requestingMetadata: hasActiveDownload = true
            case .seeding: hasSeeding = true
            default: break
            }
        }
        guard hasActiveDownload || hasSeeding else { return false }

        let onBattery = powerManager.isOnBattery

        // Seeding only (no active download): a lighter case the user can opt out of.
        if !hasActiveDownload {
            if settings.allowSleepWhileSeeding { return false }
            if settings.dontSeedOnBattery, onBattery { return false }
            return true
        }

        // Active downloads in flight. Honour the on-battery power-saving opt-outs.
        // `batteryThresholdPercent` cannot be read precisely at this layer
        // (PowerManager exposes only on-battery state), so these are best-effort:
        // while on battery we release the keep-awake hold when the user has asked
        // us to back off on battery.
        if onBattery, settings.allowSleepIfResumable { return false }
        if onBattery, settings.pauseBelowBatteryThreshold { return false }
        return true
    }

    // MARK: Watch folder

    /// Start or stop watching the configured folder per the BitTorrent settings.
    private func updateWatchFolder() async {
        guard settings.btWatchFolderEnabled, !settings.btWatchFolderPath.isEmpty else {
            await watchFolder.stop()
            return
        }
        let autoStart = settings.btWatchStartWithoutConfirmation
        await watchFolder.start(path: settings.btWatchFolderPath) { [weak self] url in
            Task { await self?.ingestWatchedTorrent(url, autoStart: autoStart) }
        }
    }

    /// Add a `.torrent` discovered in the watch folder. `add()` queues it and the
    /// scheduler promotes it automatically (the "start without confirmation"
    /// behaviour); when confirmation is required we add it then pause it so it
    /// waits for the user to explicitly resume.
    private func ingestWatchedTorrent(_ url: URL, autoStart: Bool) async {
        let task = add(source: .torrentFile(url))
        if !autoStart {
            await pause(task.id)
        }
    }

    // MARK: Backup

    /// (Re)arm the periodic backup loop per the backup settings.
    private func updateBackupSchedule() {
        backupTask?.cancel()
        backupTask = nil
        guard settings.backupEnabled, store != nil else { return }
        let hours = max(1, settings.backupIntervalHours)
        let interval = UInt64(hours) * 3600 * 1_000_000_000
        backupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                await self?.writeBackup()
            }
        }
    }

    /// Write a timestamped JSON backup of the current task list into a "Backups"
    /// subfolder of the default save directory. Off-actor so disk I/O never stalls
    /// the queue; failures are surfaced like any other persistence problem.
    private func writeBackup() async {
        guard let store else { return }
        let snapshot = tasks
        let baseDir = settings.defaultSaveDirectory
        Task.detached { [weak self] in
            do {
                let data = try store.exportTasks(snapshot)
                let dir = (baseDir as NSString).appendingPathComponent("GoelDownloader Backups")
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let stamp = Self.backupStampFormatter.string(from: Date())
                let file = (dir as NSString).appendingPathComponent("backup-\(stamp).json")
                try data.write(to: URL(fileURLWithPath: file))
            } catch {
                await self?.notePersistenceError(error)
            }
        }
    }

    private static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: Completion side-effects

    /// React to a download reaching `.completed`: optionally screen the finished
    /// file with the configured antivirus and delete a consumed local `.torrent`.
    /// Both run off-actor and best-effort — neither can stall or crash the queue.
    private func onDownloadCompleted(_ task: DownloadTask) {
        if settings.antivirusEnabled {
            let path = task.savePath
            let executable = settings.antivirusExecutablePath
            let template = settings.antivirusArgumentTemplate
            Task.detached {
                let passed = await AntivirusScanner.scan(
                    path: path, executablePath: executable, argumentTemplate: template
                )
                if !passed {
                    FileHandle.standardError.write(
                        Data("[GoelDownloader] antivirus scan flagged or failed: \(path)\n".utf8)
                    )
                }
            }
        }
        deleteSourceTorrentIfRequested(task)
    }

    /// Delete the originating local `.torrent` file once its download has the full
    /// payload, when ``AppSettings/btAutoDeleteTorrent`` is on. Only local
    /// (`file:`) `.torrent` sources are touched; remote `.torrent` URLs are left
    /// alone. Harmless if already removed.
    private func deleteSourceTorrentIfRequested(_ task: DownloadTask) {
        guard settings.btAutoDeleteTorrent,
              case let .torrentFile(url) = task.source,
              url.isFileURL else { return }
        let path = url.path
        Task.detached {
            try? FileManager.default.removeItem(atPath: path)
        }
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
            // Only a magnet that STILL lacks metadata will actually occupy a
            // metadata-resolution slot. An already-resolved (e.g. resumed) magnet
            // must not be charged against the cap — doing so would wrongly hold
            // back a fresh magnet that genuinely needs to resolve.
            let needsMetadata = Self.isMagnet(task.source) && !task.hasMetadata
            if needsMetadata, activeMetadata >= maxMetadata { continue }

            runningSlots.insert(task.id)
            let resume = engineStarted.contains(task.id)
            if !resume { engineStarted.insert(task.id) }
            setOptimisticStatus(task.id)
            launches.append((task.id, resume))
            freeSlots -= 1
            if needsMetadata { activeMetadata += 1 }
        }

        guard !launches.isEmpty else { return }
        publish()
        updatePowerAssertion()
        for launch in launches {
            Task { await self.launch(launch.id, resume: launch.resume) }
        }
        Task { await self.reapplyHTTPBudget() }
    }

    /// Reflect the imminent start in the task's status before the engine emits
    /// its own status event, so observers see the queue move immediately. A magnet
    /// without metadata starts resolving; a torrent whose payload is already
    /// complete (a paused-then-resumed seeder) goes straight back to `.seeding`
    /// rather than falsely showing `.downloading` and occupying a download slot;
    /// everything else downloads.
    private func setOptimisticStatus(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if Self.isMagnet(tasks[i].source), !tasks[i].hasMetadata {
            tasks[i].status = .requestingMetadata
        } else if tasks[i].source.kind == .torrent,
                  tasks[i].hasMetadata,
                  tasks[i].fractionCompleted >= 1.0 {
            tasks[i].status = .seeding
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

        case let .nameResolved(name):
            // Adopt the engine's resolved name (re-sanitize as defense-in-depth;
            // it strips any path components so the save path stays contained).
            tasks[i].name = DownloadTask.sanitizedName(name, fallback: tasks[i].name)

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
        // progress write 10×/sec/task is pure churn). `.finished` carries NO state
        // change (the following `.statusChanged` does), so persisting it would
        // write a stale `.downloading` snapshot that could land after — and clobber
        // — the authoritative terminal write; exclude it too.
        switch event {
        case .progress, .fileProgress, .finished:
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
    /// completion date, run completion side-effects, tear down the now-useless
    /// event subscription on a terminal state, refresh the power assertion, and
    /// promote the next queued task.
    private func handleStatusTransition(_ id: UUID, _ status: DownloadStatus) {
        switch status {
        case .completed, .failed:
            runningSlots.remove(id)
            // The task is finished — stop consuming its stream so a completed
            // download doesn't leak a live consumer Task + continuation forever.
            // (Seeding keeps its subscription: it's still active.)
            consumers[id]?.cancel()
            consumers[id] = nil
            if status == .completed, let i = index(of: id) {
                if tasks[i].completedAt == nil { tasks[i].completedAt = Date() }
                onDownloadCompleted(tasks[i])
            }
            schedule()
        case .seeding:
            runningSlots.remove(id)
            // The payload is complete the moment seeding begins — auto-delete the
            // consumed local `.torrent` now if asked (it never reaches `.completed`
            // while it seeds).
            if let i = index(of: id) { deleteSourceTorrentIfRequested(tasks[i]) }
            schedule()
        case .paused:
            runningSlots.remove(id)
            schedule()
        default:
            break
        }
        updatePowerAssertion()
    }

    // MARK: Helpers

    private func index(of id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    private func engine(for source: DownloadSource) -> any DownloadEngine {
        switch source.kind {
        case .http: return httpEngine
        case .torrent: return torrentEngine
        case .hls: return hlsEngine
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
        case let .hlsStream(url):
            return hlsDisplayName(url)
        }
    }

    /// A `.mp4` name for an HLS stream. The playlist file is usually a generic
    /// `index.m3u8` / `playlist.m3u8`, so prefer the parent path component (the
    /// title folder), falling back to the host.
    private static func hlsDisplayName(_ url: URL) -> String {
        let generic: Set<String> = ["index", "playlist", "master", "prog_index", "chunklist", "main", "video", "stream"]
        let leaf = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        let stem: String
        if !leaf.isEmpty, !generic.contains(leaf.lowercased()) {
            stem = leaf
        } else if !parent.isEmpty, parent != "/" {
            stem = parent
        } else {
            stem = url.host ?? "video"
        }
        return DownloadTask.sanitizedName(stem, fallback: "video") + ".mp4"
    }

    /// Apply the file-conflict policy to a freshly derived name. `overwrite`
    /// (or anything unrecognised) keeps the name as-is; `rename` appends
    /// ` (1)`, ` (2)`, … before the extension until the path is free. Bounded so
    /// a pathological directory can never spin forever.
    static func resolveName(_ base: String, in directory: String, policy: String) -> String {
        guard policy == "rename" else { return base }
        return DownloadTask.uniqueName(base: base, in: directory)
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
