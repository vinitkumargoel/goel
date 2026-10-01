import Foundation

public actor DownloadManager {

    let httpEngine: any DownloadEngine
    let torrentEngine: any DownloadEngine
    let hlsEngine: any DownloadEngine
    let ftpEngine: any DownloadEngine
    let sftpEngine: any DownloadEngine

    var tasks: [DownloadTask] = []

    var taskIndex: [UUID: Int] = [:]

    var dedupIndex: [String: UUID] = [:]

    /// The MDM-overlaid row every engine and scheduler path must read, so a forced key cannot be bypassed.
    var settings: AppSettings

    /// The user's own row — the only one ever persisted, so removing a profile restores their choice.
    var storedSettings: AppSettings

    var managedPolicy: ManagedPolicy

    let auditLog = AuditLog()

    let store: PersistenceStore?

    var runningSlots: Set<UUID> = []

    var engineStarted: Set<UUID> = []

    var consumers: [UUID: Task<Void, Never>] = [:]

    var autoRetryTasks: [UUID: Task<Void, Never>] = [:]

    static let autoRetryBaseDelay: TimeInterval = 2
    static let autoRetryMaxBackoff: TimeInterval = 60

    private var observers: [UUID: AsyncStream<[DownloadTask]>.Continuation] = [:]

    let power: any PowerControlling

    let folderWatch: any FolderWatching

    let scanner: any FileScanning

    var backupTask: Task<Void, Never>?

    var fileReconcileTask: Task<Void, Never>?

    /// The launch-time payload sweep, which runs after the first publish rather than before it.
    var initialReconcile: Task<Void, Never>?

    var scheduleTask: Task<Void, Never>?

    var scheduleWindowOpen = true

    var automationMemory = AutomationCore.Memory()

    var rssTask: Task<Void, Never>?
    var trackerListTask: Task<Void, Never>?

    var scheduledStartTask: Task<Void, Never>?

    var redownloadTask: Task<Void, Never>?

    var lastPathExpensive = false
    var lastPathConstrained = false

    /// Physical multi-path binds are refused while this is true — they would leak traffic outside the VPN.
    var vpnDefaultRouteActive = false

    var stats = TransferStats()

    /// Set when the saved totals couldn't be read: writing the zeroed defaults back would
    /// replace a lifetime of them with this session's.
    var statsLoadFailed = false

    var lastStatsFlush = Date.distantPast

    /// Set when the settings row couldn't be read AND couldn't be backed up: persisting now would
    /// replace the portal token, password hash, feeds and proxy with defaults, irrecoverably.
    var settingsLoadFailed = false

    var pendingNotices: [UserNotice] = []

    /// One "settings aren't being saved" notice a minute, however many changes are blocked.
    var lastBlockedSettingsNotice = Date.distantPast

    /// Torrents the scheduler found already complete: their `.seeding` is a relaunch, not a download
    /// finishing, so they are not re-quarantined (which would also re-flag files the user cleared).
    var seededFromStart: Set<UUID> = []

    /// Where inline `user:pass@` logins go — the same per-host store the HTTP engine reads.
    let credentialStore: any CredentialManaging

    /// Resume-data-only changes are coalesced per task — see ``noteResumeDataChanged(_:)``.
    var resumeDirty: Set<UUID> = []
    var lastResumeFlush: [UUID: Date] = [:]
    var resumeFlushTask: Task<Void, Never>?
    static let resumeFlushInterval: TimeInterval = 5

    /// Quit must not hang on an engine that can't reach its session; resume data is best effort.
    static let engineShutdownDeadline: TimeInterval = 5

    typealias StatsMark = StatsAccumulator.Mark
    var statsMarks: [UUID: StatsMark] = [:]

    var speedMeters: [UUID: SpeedMeter] = [:]

    let pipeline: PersistencePipeline?

    /// Where portal uploads are spooled; see ``RemoteTorrentSpool``.
    var spoolDirectory: URL? = RemoteTorrentSpool.defaultDirectory()

    /// Spooled .torrent sources of removed rows that an Undo can still bring back, per ``RemovalHold``.
    var spoolHolds: [UUID: [DownloadSource]] = [:]

    /// Rows whose partial is being copied to another folder: held out of scheduling until the move settles.
    var relocating: Set<UUID> = []

    /// Set once ``restore()`` has loaded the saved queue: until then no spool file can be called orphaned.
    var restoredQueue = false

    let persistErrorHandler: PersistenceErrorHandler?

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
        scanner: any FileScanning = ProcessFileScan(),
        credentials: any CredentialManaging = KeychainCredentialStore()
    ) {
        self.httpEngine = httpEngine
        self.torrentEngine = torrentEngine
        self.hlsEngine = hlsEngine ?? HLSEngine(profile: settings.effectiveProfile)
        self.ftpEngine = ftpEngine ?? FTPEngine(profile: settings.effectiveProfile)
        self.sftpEngine = sftpEngine ?? SFTPEngine(profile: settings.effectiveProfile)
        // Overlay applied here so even a pre-restore read of `settings` already reflects MDM policy.
        let policy = ManagedPolicy.current()
        self.managedPolicy = policy
        let stored = settings.validated()
        self.storedSettings = stored
        self.settings = policy.apply(to: stored).validated()
        self.store = store
        self.power = power
        self.folderWatch = folderWatch
        self.scanner = scanner
        self.credentialStore = credentials
        if let store {
            let handler = PersistenceErrorHandler()
            self.persistErrorHandler = handler
            self.pipeline = PersistencePipeline(store: store, errorHandler: handler)
        } else {
            self.persistErrorHandler = nil
            self.pipeline = nil
        }
    }

    public init(
        settings: AppSettings = AppSettings(),
        store: PersistenceStore? = nil,
        power: any PowerControlling = SystemPowerControl(),
        folderWatch: any FolderWatching = SystemFolderWatch(),
        scanner: any FileScanning = ProcessFileScan(),
        credentials: any CredentialManaging = KeychainCredentialStore()
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
        // Overlay applied here so even a pre-restore read of `settings` already reflects MDM policy.
        let policy = ManagedPolicy.current()
        self.managedPolicy = policy
        let stored = settings.validated()
        self.storedSettings = stored
        self.settings = policy.apply(to: stored).validated()
        self.store = store
        self.power = power
        self.folderWatch = folderWatch
        self.scanner = scanner
        self.credentialStore = credentials
        if let store {
            let handler = PersistenceErrorHandler()
            self.persistErrorHandler = handler
            self.pipeline = PersistencePipeline(store: store, errorHandler: handler)
        } else {
            self.persistErrorHandler = nil
            self.pipeline = nil
        }
    }


    public func restore() async {
        guard let store else { return }
        installPersistErrorBridge()

        do {
            let saved = try store.loadSettings()
            // Adopt even on nil: this is the only call that configures `auditLog` and applies forced policy.
            adoptStoredSettings(saved ?? storedSettings)
        } catch {
            notePersistenceError(error, stage: .loading)
            // Defaults are about to be written over the row we couldn't read — keep a raw copy first.
            noteSettingsLoadFailure(store: store)
            adoptStoredSettings(storedSettings)
        }

        do {
            if let savedStats = try store.loadStats() { stats = savedStats }
        } catch {
            // Nothing may persist `stats` now: the next progress event would UPSERT these zeros
            // over the stored row and the real lifetime totals would be gone for good.
            statsLoadFailed = true
            notePersistenceError(error, stage: .loading)
        }

        let loaded: [DownloadTask]
        let skipped: Int
        do {
            (loaded, skipped) = try store.loadAllTasksReport()
        } catch {
            // Never present an empty queue silently — it is indistinguishable from a fresh install.
            persistenceWarning = "Couldn’t restore your downloads — the saved database may be unreadable."
            GoelLog.persistence.error("Restore failed", .detail(String(describing: error)))
            publish()
            return
        }

        if skipped > 0 {
            // A partial queue with no explanation reads as data loss; the raw rows are in task_quarantine.
            let message = L10n.t("%d downloads couldn’t be read — they may have been created by a newer version of Goel°. They were kept aside, not deleted.", skipped)
            persistenceWarning = message
            postNotice(message)
        }

        // Rows from before the queue could be reordered get positions in their old start order.
        let normalized = QueueOrder.backfilled(loaded.map(Self.normalizeRestored))
        tasks = normalized
        rebuildTaskIndex()

        // Only rows normalisation changed, and in one transaction: 2,000 commits at launch is seconds of churn.
        let changed = zip(loaded, normalized).compactMap { $0 == $1 ? nil : $1 }
        if !changed.isEmpty { pipeline?.enqueue(.saveTasks(changed)) }
        // First paint must not wait on a stat of every payload: one hung SMB share would hold the window empty.
        publish()
        initialReconcile = Task { [weak self] in await self?.reconcileCompletedFiles() }
        restoredQueue = true

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
        // Rows restored as `.queued` (including interrupted ones) pick up where they left off.
        schedule()
    }

    var persistenceWarning: String?

    func installPersistErrorBridge() {
        guard let handler = persistErrorHandler else { return }
        handler.install { [weak self] error in
            await self?.notePersistenceError(error)
        }
    }

    public var snapshot: [DownloadTask] { tasks }

    public var currentSettings: AppSettings { settings }

    public var currentStats: TransferStats { stats }

    public func history(limit: Int = 1000) -> [HistoryEntry] {
        guard let store else { return [] }
        do {
            return try store.loadHistory(limit: limit)
        } catch {
            // Must not look like "no history": the user would assume it was cleared.
            GoelLog.persistence.error("History load failed", .detail(String(describing: error)))
            postNotice(L10n.t("Couldn’t read your download history — the saved database may be unreadable."))
            return []
        }
    }

    public func removeHistoryEntry(_ id: UUID) async {
        let sources = historySources([id])
        persistHistoryRemoval(id)
        await discardOrphanedSpools(sources, ignoringHistory: [id])
    }

    /// History's "Locate…": the file was moved by hand, so point the entry at where it is now.
    public func relocateHistoryEntry(_ entry: HistoryEntry, to path: String) {
        var moved = entry
        moved.savePath = path
        persistHistory(moved)
    }

    public func clearHistory() async {
        let sources = historySources(nil)
        persistHistoryClear()
        await discardOrphanedSpools(sources, ignoringAllHistory: true)
    }

    public func task(_ id: DownloadTask.ID) -> DownloadTask? {
        guard let i = index(of: id) else { return nil }
        return tasks[i]
    }

    public func updates() -> AsyncStream<[DownloadTask]> {
        // Newest only: each snapshot is the whole queue, so a stalled main thread needs just the latest.
        let (stream, continuation) = AsyncStream<[DownloadTask]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        observers[key] = continuation
        continuation.yield(tasks)
        continuation.onTermination = { [weak self] _ in
            // Bind before the `Task`: CI's toolchain rejects reading the capture-list `var self` concurrently.
            guard let self else { return }
            Task { await self.removeObserver(key) }
        }
        return stream
    }

    private func removeObserver(_ key: UUID) {
        observers[key] = nil
    }

    func publish() {
        let snapshot = tasks
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    private var lastProgressPublish = Date.distantPast
    func throttledPublish() {
        let now = Date()
        if now.timeIntervalSince(lastProgressPublish) >= 0.1 {
            lastProgressPublish = now
            publish()
        }
    }

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
        // Sanitised below and never persisted — see ``DownloadTask/cookieHeader``.
        cookieHeader: String? = nil,
        cookieSource: CookieSource? = nil,
        cookieHost: String? = nil,
        network: NetworkSelection? = nil,
        whenDone: WhenDone? = nil
    ) -> DownloadTask {
        if let existingID = dedupIndex[source.dedupKey],
           let i = index(of: existingID) {
            let existing = tasks[i]
            // "Add" means "make sure I end up with the payload". A live task — or a
            // finished one whose file is still on disk — already promises that, so the
            // duplicate maps onto it. A FAILED task does not: re-adding the source is
            // the caller retrying, so retry it. And a completed task whose file has
            // been deleted is only a record now — re-adding the source is the user
            // asking for the payload again, so the stale row gives way to a fresh task
            // rather than handing back a "Saved" that points at nothing.
            if case .failed = existing.status {
                reactivateFailed(at: i)
                return tasks[i]
            }
            if existing.status == .completed,
               existing.fileMissing == true
                || Self.completedPayloadIsMissing(existing, fileManager: FileManager.default) {
                dropTaskLocally(existingID)   // falls through to a fresh task
            } else {
                return existing
            }
        }
        // User rules sit between an explicit choice and the default-folder rule.
        let rule = AutoSortRules.firstMatch(
            in: settings.autoSortRules,
            for: AutoSortCandidate(source: source, name: suggestedName ?? Self.defaultName(for: source),
                                   size: totalBytes))
        let holdPaused = startPaused || scheduledAt != nil || rule?.startPaused == true
        let directory = saveDirectory
            ?? rule?.folder.flatMap(Self.ruleFolder)
            ?? defaultDirectory(for: source)
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
        // A malformed capture must become "no cookies", not a header that can split the request.
        let cleanedCookie = cookieHeader.flatMap(CookieHeader.sanitized)
        let task = DownloadTask(
            source: source,
            name: name,
            saveDirectory: directory,
            totalBytes: totalBytes,
            status: holdPaused ? .paused : .queued,
            priority: priority,
            files: files,
            expectedChecksum: expectedChecksum,
            scheduledAt: scheduledAt,
            mirrors: Self.sanitizedMirrors(mirrors, primary: source),
            cookieHeader: cleanedCookie,
            cookieSource: cleanedCookie == nil ? CookieSource.none : (cookieSource ?? .browser),
            // nil is not "no scope": ``sendsCookies(to:)`` then falls back to the task's own origin.
            cookieHost: cleanedCookie == nil ? nil : cookieHost,
            initialSkipFileIDs: (deselectedFileIDs?.isEmpty ?? true) ? nil : deselectedFileIDs,
            networkSelection: network == .auto ? nil : network,
            whenDone: (whenDone?.isActionable == true ? whenDone : nil) ?? rule?.whenDone
        )
        appendTask(Self.applying(rule, to: task, callerPriority: priority))
        // The stored row, not `task`: `appendTask` gives it its queue position.
        let added = tasks[tasks.count - 1]
        persist(added)
        recordAudit(.added, task: added)
        publish()
        if !holdPaused { schedule() }
        if scheduledAt != nil { armScheduledStarts() }
        return added
    }

    /// A rule's folder is only used when it is an absolute path (after `~`); anything else falls
    /// back to the default rule rather than landing relative to the process's working directory.
    static func ruleFolder(_ raw: String) -> String? {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : nil
    }

    /// Tag, speed cap and priority from a matching rule. The caller's priority wins unless it is
    /// the default, so an explicit High in the Add sheet is never lowered by a rule.
    static func applying(_ rule: AutoSortRule?, to task: DownloadTask, callerPriority: FilePriority) -> DownloadTask {
        guard let rule else { return task }
        var task = task
        if let tag = rule.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            task.tags = normalizeTags((task.tags ?? []) + [tag])
        }
        if let cap = rule.speedLimitBytesPerSec, cap > 0 { task.speedLimitBytesPerSec = cap }
        if callerPriority == .normal, let p = rule.priority { task.priority = p }
        return task
    }

    /// Mirrors are untrusted input: http(s) only, de-duplicated, and capped.
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

    public func resolveMetadata(for source: DownloadSource, saveDirectory: String? = nil) async -> DownloadPreview {
        let directory = saveDirectory ?? defaultDirectory(for: source)
        let fallbackName = Self.defaultName(for: source)
        let kind = source.kind
        let engine = engine(for: source)

        guard let meta = await engine.resolveMetadata(for: source, in: directory) else {
            let note = engine.capabilities.contains(.resolvesMetadata) ? Self.unresolvedNote(for: kind) : nil
            return DownloadPreview(
                source: source, suggestedName: fallbackName, totalBytes: nil,
                isEstimatedSize: kind == .hls, kind: kind, note: note,
                noteIsGenericUnreachable: note != nil && Self.isUnreachableNoteKind(kind))
        }

        let name = meta.name.isEmpty ? fallbackName : meta.name
        return DownloadPreview(
            source: source, suggestedName: name, totalBytes: meta.totalBytes,
            isEstimatedSize: meta.isEstimatedSize, files: meta.files, kind: kind,
            note: meta.reachable ? nil : (meta.failureNote ?? Self.unresolvedNote(for: kind)),
            suggestedChecksum: meta.suggestedChecksum,
            noteIsGenericUnreachable: !meta.reachable && meta.failureNote == nil && Self.isUnreachableNoteKind(kind))
    }

    /// The kinds whose ``unresolvedNote(for:)`` is the generic unreachable-server line.
    private static func isUnreachableNoteKind(_ kind: DownloadKind) -> Bool {
        switch kind {
        case .http, .ftp, .sftp: return true
        case .torrent, .hls: return false
        }
    }

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

    public func pause(_ id: DownloadTask.ID) async {
        guard await pauseTask(id) else { return }
        publish()
        schedule()
    }

    /// No trailing `schedule()` — during `pauseAll()` it would refill the slot being reclaimed.
    private func pauseTask(_ id: DownloadTask.ID) async -> Bool {
        guard let task = task(id) else { return false }
        guard task.status != .paused, !task.status.isTerminal else { return false }

        if engineStarted.contains(id) {
            await engine(for: task.source).pause(id)
        }
        runningSlots.remove(id)
        // Re-validate after the await: never clobber a terminal state reached while suspended.
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

    public func resume(_ id: DownloadTask.ID) async {
        guard resumeTask(id) else { return }
        publish()
        schedule()
    }

    private func resumeTask(_ id: DownloadTask.ID) -> Bool {
        guard let i = index(of: id), tasks[i].status == .paused else { return false }
        tasks[i].status = .queued
        tasks[i].scheduledAt = nil
        persist(tasks[i])
        return true
    }

    public func retry(_ id: DownloadTask.ID) async {
        guard let i = index(of: id), case .failed = tasks[i].status else { return }
        reactivateFailed(at: i)
    }

    /// Shared by `retry` and by `add` when a duplicate source lands on a failed task.
    func reactivateFailed(at i: Int) {
        let id = tasks[i].id
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

    func scheduleAutoRetryIfNeeded(_ id: DownloadTask.ID) {
        guard settings.autoRetryEnabled, settings.autoRetryMaxAttempts > 0 else { return }
        guard let i = index(of: id), case .failed(let error) = tasks[i].status else { return }
        // Retrying against a full disk only fails again and churns the volume; the user must free space.
        if Self.isDiskFull(error) { return }
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

    /// Not every engine maps ENOSPC to `.diskFull` (HLS/ffmpeg and libtorrent report text), so match that too.
    static func isDiskFull(_ error: DownloadError) -> Bool {
        let text: String
        switch error {
        case .diskFull: return true
        case .network(let message), .unknown(let message): text = message.lowercased()
        default: return false
        }
        return text.contains("enospc") || text.contains("no space left")
            || text.contains("not enough disk space") || text.contains("disk is full")
    }

    /// Recheck `.failed`: the user may have removed, resumed or retried it while the timer waited.
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

    public func shutdown() async {
        // Engines first, while consumers still run, so their last resume data reaches the rows flushed below.
        await shutdownEngines()
        for _ in 0..<8 { await Task.yield() }
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
        initialReconcile?.cancel()
        initialReconcile = nil
        let folderWatch = self.folderWatch
        await folderWatch.stop()
        power.setPreventSleep(false)
        flushPendingResumeData()
        persistStats(force: true)
        await pipeline?.shutdown()
    }

    /// Each distinct engine once (tests pass one mock for several kinds), all in parallel, bounded overall.
    func shutdownEngines(deadline: TimeInterval = DownloadManager.engineShutdownDeadline) async {
        var seen = Set<ObjectIdentifier>()
        let engines = [httpEngine, torrentEngine, hlsEngine, ftpEngine, sftpEngine]
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
        let finished = await Self.runWithDeadline(seconds: deadline) {
            await withTaskGroup(of: Void.self) { group in
                for engine in engines { group.addTask { await engine.shutdown() } }
            }
        }
        if !finished {
            GoelLog.scheduler.error("Engine shutdown missed its deadline — quitting anyway")
        }
    }

    /// True when `work` finished in time. A task group can't do this: it waits for children that ignore cancellation.
    static func runWithDeadline(seconds: TimeInterval,
                                _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let gate = OnceGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.claim() { continuation.resume(returning: false) }
            }
            Task {
                await work()
                timer.cancel()
                if gate.claim() { continuation.resume(returning: true) }
            }
        }
    }

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

    /// Seed from ``storedSettings``, never the overlaid row, or forced MDM keys outlive their profile.
    @discardableResult
    public func apply(_ change: @Sendable (inout AppSettings) -> Void) async -> AppSettings {
        var copy = storedSettings
        change(&copy)
        await updateSettings(copy)
        return settings
    }

    @discardableResult
    public func setProfile(_ name: String) async -> AppSettings {
        await apply { $0.selectedProfileName = name }
    }

    @discardableResult
    public func setSpeedLimitEnabled(_ enabled: Bool) async -> AppSettings {
        await apply { $0.speedLimitEnabled = enabled }
    }

    @discardableResult
    public func setDefaultSaveDirectory(_ path: String) async -> AppSettings {
        var updated = storedSettings
        updated.defaultSaveDirectory = path
        adoptStoredSettings(updated)
        persistSettings()
        publish()
        return settings
    }

    func recordAudit(_ action: AuditEvent.Action, task: DownloadTask) {
        guard settings.auditLogEnabled else { return }
        Task { [auditLog] in await auditLog.record(action, task: task) }
    }

    public func auditLogDirectory() async -> URL? {
        await auditLog.currentDirectory()
    }

    /// The only writer of ``storedSettings``; validates *after* the overlay so forced values still clamp.
    func adoptStoredSettings(_ newSettings: AppSettings) {
        storedSettings = newSettings.validated()
        settings = managedPolicy.apply(to: storedSettings).validated()
        let auditConfiguration = AuditLog.Configuration(settings: settings)
        Task { [auditLog] in await auditLog.configure(auditConfiguration) }
    }

    /// Must run on re-activation: a launch-only policy is one the user dodges by never quitting.
    public func refreshManagedPolicy() async {
        let policy = ManagedPolicy.current()
        guard policy != managedPolicy else { return }
        managedPolicy = policy
        await updateSettings(storedSettings)
    }

    public func currentManagedPolicy() -> ManagedPolicy { managedPolicy }

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

    public func setSequential(_ sequential: Bool, task id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.setSequential(sequential, task: id)
        if let i = index(of: id) {
            tasks[i].sequentialDownload = sequential
            persist(tasks[i])
        }
        publish()
    }

    public func setTaskSpeedLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) async {
        _ = mutateTask(id) {
            $0.speedLimitBytesPerSec = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
        }
        await refreshEngineCopy(id)
    }

    /// An engine that has seen a task keeps its own copy; a stopped task must not resume with the old one.
    func refreshEngineCopy(_ id: DownloadTask.ID) async {
        guard engineStarted.contains(id), let task = task(id), !task.status.isActive else { return }
        await engine(for: task.source).refresh(task)
    }

    public func setTaskUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.setUploadLimit(bytesPerSec, task: id)
        // Re-resolve after the actor hop: an index taken before the await can now be stale or out of range.
        if let i = index(of: id) {
            tasks[i].uploadLimitBytesPerSec = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
            persist(tasks[i])
        }
        publish()
    }

    /// nil restores the profile limit; an explicit 0 means "seed forever" and overrides it.
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

    public func forceRecheck(_ id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.forceRecheck(id)
    }

    public func forceReannounce(_ id: DownloadTask.ID) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? TorrentControlling)?.forceReannounce(id)
    }

    /// A waiting download's place among the others; the scheduler reads it when a slot frees.
    public func setPriority(_ priority: FilePriority, task id: DownloadTask.ID) async {
        guard mutateTask(id, { $0.priority = priority }) else { return }
        schedule()
    }

    public func setLabel(_ label: String?, task id: DownloadTask.ID) async {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = mutateTask(id) {
            $0.label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    public func setTags(_ tags: [String], task id: DownloadTask.ID) async {
        let cleaned = Self.normalizeTags(tags)
        _ = mutateTask(id) {
            $0.tags = cleaned.isEmpty ? nil : cleaned
        }
    }

    public func setNote(_ note: String?, task id: DownloadTask.ID) async {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = mutateTask(id) {
            $0.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

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
        await refreshEngineCopy(id)
        return raw.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { Self.reservedHeaderNames.contains($0) }
            .sorted()
    }

    /// The cookie header stays in memory only — it is excluded from `Codable` and never persisted.
    public func setCookies(_ raw: String?, host: String?, source: CookieSource,
                           task id: DownloadTask.ID) async {
        guard let i = index(of: id) else { return }
        let cleaned = raw.flatMap(CookieHeader.sanitized)
        tasks[i].cookieHeader = cleaned
        tasks[i].cookieSource = cleaned == nil ? CookieSource.none : source
        tasks[i].cookieHost = cleaned == nil ? nil : (host ?? tasks[i].sourceHost)
        persist(tasks[i])
        publish()
        await refreshEngineCopy(id)
    }

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

    static let reservedHeaderNames: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding", "keep-alive",
        "upgrade", "te", "trailer", "referer", "authorization", "proxy-authorization",
        "proxy-connection",
        // `cookie` is reserved: this editor persists to SQLite and the JSON export, so use `setCookies`.
        "cookie"
    ]

    /// Drops reserved, empty and control-char headers — a CR/LF/NUL would let a value split the request.
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

    /// CR, LF and NUL are the header/response-splitting vectors — they must never reach a header.
    static func hasHeaderControlChars(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0.value == 0 }
    }

    public func exportEnvelope() throws -> Data {
        let envelope = AppExport(settings: Self.exportSanitizedSettings(settings), tasks: tasks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(envelope)
    }

    /// A backup may be synced or attached to a bug report: the token and password hash must not travel in it.
    static func exportSanitizedSettings(_ s: AppSettings) -> AppSettings {
        var out = s
        out.remoteToken = ""
        out.remotePasswordHash = ""
        return out
    }

    /// A backup is untrusted: settings that run code, open a port, redirect traffic or move files never apply.
    @discardableResult
    public func importEnvelope(_ data: Data) async throws -> Int {
        let envelope = try JSONDecoder().decode(AppExport.self, from: data)
        var added = 0
        for imported in envelope.tasks {
            // Contained by the CURRENT save folder: the imported settings' own folder is ignored below.
            let task = PersistenceStore.sanitizedForImport(imported,
                                                           defaultDirectory: settings.defaultSaveDirectory)
            // Untrusted input may repeat a task id; `taskIndex` keys on it, so the loser becomes a zombie row.
            guard index(of: task.id) == nil else { continue }
            // A local `.torrent` path in a shared backup points at the importer's disk, not the author's.
            if case .torrentFile(let url) = task.source, url.isFileURL { continue }
            guard dedupIndex[task.source.dedupKey] == nil else { continue }
            var t = Self.normalizeRestored(task)
            // Another machine's queue numbers mean nothing here: imports join the back of the line.
            t.queuePosition = nil
            appendTask(t)
            persist(tasks[tasks.count - 1])
            added += 1
        }
        // `storedSettings`, not `settings`: persisting the overlaid row would freeze forced MDM keys in.
        await updateSettings(Self.sanitizedImportedSettings(envelope.settings, current: storedSettings))
        return added
    }

    /// Every security-sensitive field is forced back to the CURRENT value; add new ones here too.
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
        // ffmpeg path is an executable we run: adopting an imported one is arbitrary code execution.
        safe.ffmpegPath = current.ffmpegPath
        // The WHOLE `remote*` family, not just the switch: credentials and proxy trust each hand over the portal.
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
        safe.remoteAllowedHostNames = current.remoteAllowedHostNames
        // An imported proxy would route every connection, cookies and Basic-auth included, through its author's host.
        safe.proxyMode = current.proxyMode
        safe.proxyType = current.proxyType
        safe.proxyHost = current.proxyHost
        safe.proxyPort = current.proxyPort
        safe.proxyAllProtocols = current.proxyAllProtocols
        // The save folder is the containment root the portal validates every requested path against.
        safe.defaultSaveDirectory = current.defaultSaveDirectory
        safe.auditLogDirectory = current.auditLogDirectory
        safe.rssFeeds = current.rssFeeds
        safe.btWatchFolderEnabled = current.btWatchFolderEnabled
        safe.btWatchFolderPath = current.btWatchFolderPath
        safe.btWatchStartWithoutConfirmation = current.btWatchStartWithoutConfirmation
        safe.updateFeedURL = current.updateFeedURL
        // Silently switching off the audit trail, arming a shutdown or deleting .torrent files is not a preference to adopt.
        safe.auditLogEnabled = current.auditLogEnabled
        safe.autoShutdownAction = current.autoShutdownAction
        safe.btAutoDeleteTorrent = current.btAutoDeleteTorrent
        return safe
    }

    public func setFilePriority(
        _ priority: FilePriority,
        fileID: Int,
        task id: DownloadTask.ID
    ) async {
        guard let task = task(id) else { return }
        await (engine(for: task.source) as? FilePrioritizing)?.setFilePriority(priority, fileID: fileID, task: id)
        if let i = index(of: id) {
            if let f = tasks[i].files.firstIndex(where: { $0.id == fileID }) {
                tasks[i].files[f].priority = priority
            }
            // Drop the add-time skip entry, or a later resume silently re-skips what the user re-enabled.
            tasks[i].initialSkipFileIDs?.removeAll { $0 == fileID }
            persist(tasks[i])
        }
        publish()
    }

    private func defaultDirectory(for source: DownloadSource) -> String {
        let base = settings.defaultSaveDirectory
        switch settings.defaultFolderRule {
        case "byType", "automatic":
            return (base as NSString).appendingPathComponent(Self.categoryFolder(for: source))
        case "bySource":
            let bucket = source.kind == .torrent ? "Torrents" : "HTTP Downloads"
            return (base as NSString).appendingPathComponent(bucket)
        default:
            return base
        }
    }

    func index(of id: UUID) -> Int? {
        if let i = taskIndex[id], i < tasks.count, tasks[i].id == id { return i }
        rebuildTaskIndex()
        return taskIndex[id]
    }

    /// Never `Dictionary(uniqueKeysWithValues:)`: a legacy duplicate `dedupKey` traps on every launch.
    func rebuildTaskIndex() {
        taskIndex.removeAll(keepingCapacity: true)
        dedupIndex.removeAll(keepingCapacity: true)
        for (offset, task) in tasks.enumerated() {
            taskIndex[task.id] = offset
            let key = task.source.dedupKey
            if dedupIndex[key] == nil { dedupIndex[key] = task.id }
        }
    }

    /// Every row enters at the back of the queue unless it already carries a place (an undone
    /// removal puts the row back where it stood).
    func appendTask(_ task: DownloadTask) {
        var task = task
        if task.queuePosition == nil { task.queuePosition = QueueOrder.nextPosition(in: tasks) }
        taskIndex[task.id] = tasks.count
        dedupIndex[task.source.dedupKey] = task.id
        tasks.append(task)
    }

    func removeTask(at i: Int) {
        let removed = tasks[i]
        let key = removed.source.dedupKey
        tasks.remove(at: i)
        taskIndex[removed.id] = nil
        if dedupIndex[key] == removed.id {
            // Hand the key to a surviving duplicate; leaving it unindexed lets the source be added again.
            dedupIndex[key] = tasks.first { $0.source.dedupKey == key }?.id
        }
        for j in i..<tasks.count {
            taskIndex[tasks[j].id] = j
        }
    }

    static func normalizeRestored(_ task: DownloadTask) -> DownloadTask {
        var t = task
        // Interrupted work goes back in line rather than to `.paused`, which is reserved for the user's
        // choice — else "Start All" after a relaunch also resumes what they paused on purpose.
        switch t.status {
        case .downloading, .verifying, .requestingMetadata, .seeding:
            t.status = .queued
        default:
            break
        }
        t.downloadSpeed = 0
        t.uploadSpeed = 0
        t.connectionCount = 0
        t.connections = nil
        return t
    }

    func clearLocalState(_ id: UUID, removeFromList: Bool) {
        autoRetryTasks[id]?.cancel()
        autoRetryTasks[id] = nil
        consumers[id]?.cancel()
        consumers[id] = nil
        runningSlots.remove(id)
        engineStarted.remove(id)
        statsMarks[id] = nil
        speedMeters[id] = nil
        resumeDirty.remove(id)
        lastResumeFlush[id] = nil
        seededFromStart.remove(id)
        if removeFromList, let i = index(of: id) {
            removeTask(at: i)
        }
    }

    func clearLiveRates(_ id: UUID) {
        if let i = index(of: id) {
            tasks[i].downloadSpeed = 0
            tasks[i].uploadSpeed = 0
        }
        speedMeters[id] = nil
    }

    @discardableResult
    func mutateTask(_ id: UUID, publishAfter: Bool = true,
                    _ body: (inout DownloadTask) -> Void) -> Bool {
        guard let i = index(of: id) else { return false }
        body(&tasks[i])
        persist(tasks[i])
        if publishAfter { publish() }
        return true
    }

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

/// Exactly-once latch for ``DownloadManager/runWithDeadline(seconds:_:)``: a continuation resumed twice traps.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
