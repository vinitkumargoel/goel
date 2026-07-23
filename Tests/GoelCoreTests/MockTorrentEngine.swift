import Foundation
import GoelCore

/// A **simulated** BitTorrent engine — a ``TorrentControlling`` test double for
/// `.torrent` sources (`.magnet` and `.torrentFile`). It lives in the test
/// target (the real libtorrent engine ships in `GoelTorrent`); the scheduler
/// tests inject it via the primary ``DownloadManager`` init to exercise the
/// torrent lifecycle without a network or libtorrent.
///
/// It performs no real networking. Instead it drives a deterministic, time-based
/// simulation that exercises every part of the unified `DownloadTask` model that
/// the HTTP engine does not:
///
///  * a pre-metadata `.requestingMetadata` phase for magnets, resolving after a
///    configurable delay into a realistic **multi-file** payload,
///  * immediate metadata for `.torrentFile` sources,
///  * periodic `.progress` carrying **both** download *and* upload activity and a
///    fluctuating peer (`connectionCount`),
///  * per-file `.fileProgress`,
///  * a distinct **seeding** lifecycle: on reaching 100% it emits `.finished`
///    then `.statusChanged(.seeding)` (never `.completed` directly) and keeps
///    uploading until `shareRatio` reaches the applied profile's
///    `seedRatioLimit`, at which point it transitions to `.completed`,
///  * per-file selection: `setFilePriority(.skip,…)` drops a file from the wanted
///    set, shrinking the effective work the simulation has to complete.
///
/// The simulation is fully driven by an injectable ``Simulation`` (tick interval,
/// bytes-per-tick, metadata delay, peer range). Tests inject a fast tick so the
/// whole lifecycle runs in milliseconds without real sleeps dominating; the
/// `.demo` defaults model a realistic pace (~32 MB/s, ~1.5 s to resolve a magnet).
///
/// Like `HTTPEngine` it is an `actor` (so all mutable bookkeeping is serialized
/// and it is `Sendable` for free); the synchronous `kind` requirement is met by a
/// `nonisolated let`, and `events(for:)` is satisfied by a `nonisolated` hub.
actor MockTorrentEngine: TorrentControlling {

    // MARK: Identity

    public nonisolated let kind: DownloadKind = .torrent

    /// Mirrors ``TorrentEngine``: the mock synthesises a file list up front and
    /// honours per-file priority, but emits no resume-data blobs.
    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata, .perFilePriority] }

    /// Lock-based fan-out of events to subscribers. Lives outside the actor's
    /// isolation so the synchronous `events(for:)` requirement can be satisfied
    /// by a `nonisolated` method. Uses the shared ``EventHub`` — the same
    /// broadcaster every other engine holds.
    private nonisolated let hub = EventHub()

    // MARK: Tunables

    /// Knobs controlling the pace and shape of the simulation.
    struct Simulation: Sendable, Hashable {
        /// Wall-clock seconds between simulation ticks. `0` ticks as fast as the
        /// cooperative scheduler allows (used for instant tests).
        var tickInterval: TimeInterval
        /// Simulated bytes downloaded per tick (before any profile cap).
        var bytesPerTick: Int64
        /// Simulated bytes uploaded per tick, both while downloading (tit-for-tat)
        /// and while seeding.
        var uploadBytesPerTick: Int64
        /// How many `.requestingMetadata` ticks a magnet waits before its metadata
        /// resolves. Ignored for `.torrentFile` sources (metadata is immediate).
        var metadataDelayTicks: Int
        /// Lower bound of the simulated peer count.
        var minPeers: Int
        /// Upper bound of the simulated peer count.
        var maxPeers: Int

        init(
            tickInterval: TimeInterval = 0.25,
            bytesPerTick: Int64 = 8 * 1024 * 1024,
            uploadBytesPerTick: Int64 = 1024 * 1024,
            metadataDelayTicks: Int = 6,
            minPeers: Int = 4,
            maxPeers: Int = 48
        ) {
            self.tickInterval = tickInterval
            self.bytesPerTick = bytesPerTick
            self.uploadBytesPerTick = uploadBytesPerTick
            self.metadataDelayTicks = metadataDelayTicks
            self.minPeers = minPeers
            self.maxPeers = maxPeers
        }

        /// Pleasant defaults for a live demo (~32 MB/s, 1.5 s to resolve a magnet).
        static let demo = Simulation()
    }

    // MARK: Dependencies

    private let sim: Simulation

    /// The active traffic profile. Drives the seed-ratio cutoff and the bandwidth
    /// / connection caps.
    private var profile: TrafficProfile

    // MARK: Per-task state

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var states: [UUID: SimState] = [:]

    /// Last time a `.progress`/`.fileProgress` beat was emitted per task, used to
    /// throttle progress emission to ~12 Hz. State still advances every tick; only
    /// the *emission* is rate-limited, so a fast simulation doesn't flood the
    /// manager's event stream (which would back up lifecycle events behind a long
    /// progress backlog). Lifecycle events are always emitted, unthrottled.
    private var lastProgressEmit: [UUID: Date] = [:]
    private static let progressEmitInterval: TimeInterval = 0.08

    // MARK: Init

    /// - Parameters:
    ///   - simulation: pace/shape of the simulation. Defaults to `.demo`.
    ///   - profile: initial traffic profile (its `seedRatioLimit` decides when
    ///     seeding stops). Defaults to `.high`.
    init(simulation: Simulation = .demo, profile: TrafficProfile = .high) {
        self.sim = simulation
        self.profile = profile
    }

    // MARK: DownloadEngine

    func add(_ task: DownloadTask) async {
        guard tasks[task.id] == nil else { return }
        tasks[task.id] = task
        // Seed the simulation from the task's persisted progress so a torrent
        // restored from disk doesn't replay phases it already finished: a task
        // with known metadata skips the "requesting info" phase, and a fully
        // downloaded one (e.g. a restored seeding torrent) jumps straight into
        // the seeding loop instead of re-emitting the metadata/finished beats.
        var state = SimState()
        if task.totalBytes != nil { state.metadataResolved = true }
        if let total = task.totalBytes, total > 0, task.bytesDownloaded >= total {
            state.finishedEmitted = true
        }
        states[task.id] = state
        let id = task.id
        jobs[id] = Task { await self.run(id) }
    }

    func pause(_ id: DownloadTask.ID) async {
        guard let job = jobs[id] else { return }
        job.cancel()
        jobs[id] = nil
        tasks[id]?.status = .paused
        tasks[id]?.downloadSpeed = 0
        tasks[id]?.uploadSpeed = 0
        tasks[id]?.connectionCount = 0   // a paused torrent has no live peers
        // Note: the manager owns the .paused transition (it called pause()). We do
        // NOT echo .statusChanged(.paused) — a stale echo arriving after a later
        // resume would wrongly flip the task back to paused and strand it.
    }

    func resume(_ id: DownloadTask.ID) async {
        guard tasks[id] != nil, jobs[id] == nil else { return }
        if states[id] == nil { states[id] = SimState() }
        // run() re-emits the appropriate status (downloading or seeding) for the
        // phase it resumes into.
        jobs[id] = Task { await self.run(id) }
    }

    func remove(_ id: DownloadTask.ID, deleteData: Bool) async {
        let job = jobs[id]
        job?.cancel()
        jobs[id] = nil
        await job?.value
        if deleteData, let task = tasks[id], task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
        tasks[id] = nil
        states[id] = nil
        lastProgressEmit[id] = nil
    }

    /// Whether a progress beat should be emitted now (rate-limited per task).
    private func shouldEmitProgress(_ id: UUID) -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastProgressEmit[id] ?? .distantPast) >= Self.progressEmitInterval {
            lastProgressEmit[id] = now
            return true
        }
        return false
    }

    func applyLimits(_ profile: TrafficProfile) async {
        self.profile = profile
    }

    /// Adopts new session-level BitTorrent settings. The mock does no real
    /// networking, so this is a no-op passthrough (protocol surface only).
    func applySessionConfig(_ config: TorrentSessionConfig) async {}

    /// Apply the session-level BitTorrent settings (no-op passthrough — the mock
    /// does no real networking). PeX still rides through the shared config type.
    func configure(_ session: TorrentSessionConfig) async {
        await applySessionConfig(session)
    }

    /// Record the sequential-download preference for a task. The mock has no wire
    /// protocol, so this only updates the tracked task's flag.
    func setSequential(_ sequential: Bool, task id: DownloadTask.ID) async {
        tasks[id]?.sequentialDownload = sequential
    }

    // Torrent maintenance/seeding controls — the mock records the caps and treats
    // the recheck/reannounce as no-ops (no real session to drive).
    func setUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) async {
        tasks[id]?.uploadLimitBytesPerSec = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
    }
    func setSeedRatioLimit(_ ratio: Double?, task id: DownloadTask.ID) async {
        tasks[id]?.seedRatioLimit = (ratio ?? 0) > 0 ? ratio : nil
    }
    func forceRecheck(_ id: DownloadTask.ID) async {}
    func forceReannounce(_ id: DownloadTask.ID) async {}

    /// Resolve metadata for the add-confirmation preview through the engine-agnostic
    /// seam. The mock has no real network, so it returns the same synthesised
    /// multi-file payload its run loop would produce, exercising the preview path.
    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        let meta = Self.synthesizeMetadata(name: "")
        return EngineMetadata(name: meta.name, totalBytes: meta.total, files: meta.files)
    }

    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) async {
        guard var task = tasks[id] else { return }
        guard let idx = task.files.firstIndex(where: { $0.id == fileID }) else { return }
        task.files[idx].priority = priority
        tasks[id] = task

        // Un-skipping a file can add new wanted bytes after the run loop has already
        // passed its download gate — either while it is parked in the seeding loop
        // (which never re-evaluates downloadComplete) or after completion (no job at
        // all). A real client resumes the transfer in that case; the simulation must
        // too, otherwise the now-wanted file would stay incomplete forever while the
        // task keeps reporting 100%. Re-arm the run loop so the bytes are fetched.
        // The .paused case is left to resume(), which re-enters run() and re-derives
        // the wanted set itself.
        guard priority != .skip,
              wantedRemaining(id) > 0,
              tasks[id]?.status != .paused
        else { return }
        jobs[id]?.cancel()
        jobs[id] = nil
        // Allow the closing .finished to re-emit once the newly-wanted bytes land.
        states[id]?.finishedEmitted = false
        jobs[id] = Task { await self.run(id) }
    }

    nonisolated func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        hub.subscribe(id)
    }

    // MARK: Inspection (additive, used by tests / the manager)

    /// A snapshot of the engine's current view of a task, or `nil` if unknown.
    func snapshot(_ id: DownloadTask.ID) -> DownloadTask? {
        tasks[id]
    }

    // MARK: Driver

    /// The full simulated lifecycle. Re-entrant: on `resume` it inspects stored
    /// state and continues from the metadata, downloading, or seeding phase.
    private func run(_ id: UUID) async {
        guard tasks[id] != nil else { return }
        if states[id] == nil { states[id] = SimState() }

        // 1. Metadata.
        if states[id]?.metadataResolved == false {
            if case .magnet = tasks[id]!.source {
                tasks[id]?.status = .requestingMetadata
                emit(id, .statusChanged(.requestingMetadata))
                for _ in 0..<max(0, sim.metadataDelayTicks) {
                    do { try await tick(id) } catch { return }
                    emitConnecting(id)
                }
            }
            let meta = resolveMetadata(for: tasks[id]!)
            if tasks[id]?.files.isEmpty ?? true { tasks[id]?.files = meta.files }
            tasks[id]?.totalBytes = meta.total
            if tasks[id]?.name.isEmpty ?? true { tasks[id]?.name = meta.name }
            states[id]?.metadataResolved = true
            emit(id, .metadataResolved(name: tasks[id]!.name, totalBytes: meta.total, files: tasks[id]!.files))
        }

        // 2. Downloading.
        if !downloadComplete(id) {
            tasks[id]?.status = .downloading
            emit(id, .statusChanged(.downloading))
            while !downloadComplete(id) {
                do { try await tick(id) } catch { return }
                applyDownloadTick(id)
            }
        }

        // 3. 100% reached: finish, then begin seeding (never .completed directly).
        if states[id]?.finishedEmitted == false {
            finalizeDownload(id)
            states[id]?.finishedEmitted = true
            emit(id, .finished)
            tasks[id]?.status = .seeding
            tasks[id]?.downloadSpeed = 0
            emit(id, .statusChanged(.seeding))
        }

        // 4. Seeding: keep uploading until the share ratio hits the limit.
        if !seedRatioReached(id) {
            if tasks[id]?.status != .seeding {
                // Resumed straight into the seeding phase.
                tasks[id]?.status = .seeding
                emit(id, .statusChanged(.seeding))
            }
            while !seedRatioReached(id) {
                do { try await tick(id) } catch { return }
                applySeedTick(id)
            }
        }

        // 5. Seed ratio satisfied: the torrent is done.
        guard tasks[id] != nil else { return }
        tasks[id]?.status = .completed
        tasks[id]?.completedAt = Date()
        tasks[id]?.downloadSpeed = 0
        tasks[id]?.uploadSpeed = 0
        tasks[id]?.connectionCount = 0
        jobs[id] = nil
        emit(id, .statusChanged(.completed))
    }

    // MARK: Ticking

    /// Advances the simulated clock by one tick, honouring cancellation.
    private func tick(_ id: UUID) async throws {
        if sim.tickInterval > 0 {
            try await Task.sleep(nanoseconds: UInt64((sim.tickInterval * 1_000_000_000).rounded()))
        } else {
            await Task.yield()
        }
        try Task.checkCancellation()
        states[id]?.tick += 1
    }

    /// A pre-metadata progress beat: 0 bytes, a handful of peers connecting.
    private func emitConnecting(_ id: UUID) {
        let peers = peerCount(id)
        tasks[id]?.connectionCount = peers
        emit(id, .progress(
            bytesDownloaded: 0,
            bytesUploaded: tasks[id]?.bytesUploaded ?? 0,
            downloadSpeed: 0,
            uploadSpeed: 0,
            connectionCount: peers
        ))
    }

    /// Distributes this tick's download budget across the wanted, incomplete files
    /// in order, accrues some upload, and broadcasts progress.
    private func applyDownloadTick(_ id: UUID) {
        guard var task = tasks[id] else { return }
        let emitNow = shouldEmitProgress(id)
        var budget = effectiveDownloadBytesPerTick()
        let before = budget

        for i in task.files.indices {
            if budget <= 0 { break }
            guard task.files[i].isWanted else { continue }
            let remaining = task.files[i].length - task.files[i].bytesCompleted
            if remaining <= 0 { continue }
            let take = min(remaining, budget)
            task.files[i].bytesCompleted += take
            budget -= take
            if emitNow { emit(id, .fileProgress(fileID: task.files[i].id, bytesCompleted: task.files[i].bytesCompleted)) }
        }

        let taken = before - budget
        let downloaded = task.files.reduce(0) { $0 + $1.bytesCompleted }
        let up = effectiveUploadBytesPerTick()

        task.bytesDownloaded = downloaded
        task.bytesUploaded += up
        task.downloadSpeed = speed(taken)
        task.uploadSpeed = speed(up)
        task.connectionCount = peerCount(id)
        tasks[id] = task

        if emitNow {
            emit(id, .progress(
                bytesDownloaded: downloaded,
                bytesUploaded: task.bytesUploaded,
                downloadSpeed: task.downloadSpeed,
                uploadSpeed: task.uploadSpeed,
                connectionCount: task.connectionCount
            ))
        }
    }

    /// Settles the final downloaded byte count and emits a closing progress beat.
    private func finalizeDownload(_ id: UUID) {
        guard var task = tasks[id] else { return }
        let downloaded = task.files.reduce(0) { $0 + $1.bytesCompleted }
        task.bytesDownloaded = downloaded
        task.downloadSpeed = 0
        task.connectionCount = peerCount(id)
        tasks[id] = task
        emit(id, .progress(
            bytesDownloaded: downloaded,
            bytesUploaded: task.bytesUploaded,
            downloadSpeed: 0,
            uploadSpeed: task.uploadSpeed,
            connectionCount: task.connectionCount
        ))
    }

    /// One seeding beat: upload only, download speed pinned at 0.
    private func applySeedTick(_ id: UUID) {
        guard var task = tasks[id] else { return }
        let emitNow = shouldEmitProgress(id)
        let up = effectiveUploadBytesPerTick()
        task.bytesUploaded += up
        task.downloadSpeed = 0
        task.uploadSpeed = speed(up)
        task.connectionCount = peerCount(id)
        tasks[id] = task
        if emitNow {
            emit(id, .progress(
                bytesDownloaded: task.bytesDownloaded,
                bytesUploaded: task.bytesUploaded,
                downloadSpeed: 0,
                uploadSpeed: task.uploadSpeed,
                connectionCount: task.connectionCount
            ))
        }
    }

    // MARK: Phase predicates

    /// Bytes still owed across the wanted (non-skipped) files.
    private func wantedRemaining(_ id: UUID) -> Int64 {
        guard let task = tasks[id] else { return 0 }
        return task.files.reduce(0) { acc, file in
            guard file.isWanted else { return acc }
            return acc + max(0, file.length - file.bytesCompleted)
        }
    }

    private func downloadComplete(_ id: UUID) -> Bool {
        wantedRemaining(id) == 0
    }

    private func seedRatioReached(_ id: UUID) -> Bool {
        guard let task = tasks[id] else { return true }
        // A per-task limit (set via `setSeedRatioLimit`) overrides the engine-wide
        // profile default, matching the real `TorrentEngine`'s behaviour.
        let limit = task.seedRatioLimit ?? profile.seedRatioLimit
        if limit <= 0 { return true }      // no seeding requested
        if task.bytesDownloaded <= 0 { return true }        // nothing to seed
        return task.shareRatio >= limit
    }

    // MARK: Profile-aware rates

    private func effectiveDownloadBytesPerTick() -> Int64 {
        let base = max(1, sim.bytesPerTick)
        let cap = profile.maxDownloadBytesPerSec
        guard cap > 0, sim.tickInterval > 0 else { return base }
        let perTick = Int64(Double(cap) * sim.tickInterval)
        return max(1, min(base, perTick))
    }

    private func effectiveUploadBytesPerTick() -> Int64 {
        let base = max(0, sim.uploadBytesPerTick)
        let cap = profile.maxUploadBytesPerSec
        guard cap > 0, sim.tickInterval > 0 else { return base }
        let perTick = Int64(Double(cap) * sim.tickInterval)
        // Mirror the download helper's floor: a tiny upload cap combined with a
        // short tick interval can truncate `perTick` to 0, which would stall upload
        // accounting and loop the seed phase forever (shareRatio never rises).
        return max(1, min(base, perTick))
    }

    private func speed(_ bytesThisTick: Int64) -> Double {
        guard bytesThisTick > 0 else { return 0 }
        if sim.tickInterval > 0 { return Double(bytesThisTick) / sim.tickInterval }
        return Double(bytesThisTick) * 60 // nominal display rate when ticking instantly
    }

    /// A deterministic, gently fluctuating peer count within the configured range
    /// and the profile's connection cap.
    private func peerCount(_ id: UUID) -> Int {
        let t = states[id]?.tick ?? 0
        let lo = max(0, sim.minPeers)
        let hi = max(lo, sim.maxPeers)
        let span = hi - lo
        let raw = span == 0 ? lo : lo + ((t * 7 + 3) % (span + 1))
        let maxConn = profile.maxConnections > 0 ? profile.maxConnections : Int.max
        return min(raw, maxConn)
    }

    // MARK: Metadata

    private func resolveMetadata(for task: DownloadTask) -> (name: String, total: Int64, files: [TransferFile]) {
        if !task.files.isEmpty {
            let total = task.totalBytes ?? task.files.reduce(0) { $0 + $1.length }
            return (task.name, total, task.files)
        }
        return Self.synthesizeMetadata(name: task.name)
    }

    /// Builds a realistic multi-file payload (a season pack: several episodes plus
    /// a sample, an `.nfo` and a poster) so the multi-file model is exercised.
    static func synthesizeMetadata(name: String) -> (name: String, total: Int64, files: [TransferFile]) {
        let mb: Int64 = 1024 * 1024
        let kb: Int64 = 1024
        let base = name.isEmpty ? "Cosmos.Documentary.S01.1080p.WEB" : name

        var files: [TransferFile] = []
        var id = 0
        let episodeSizes: [Int64] = [612 * mb, 588 * mb, 640 * mb, 575 * mb, 631 * mb]
        for (i, size) in episodeSizes.enumerated() {
            files.append(TransferFile(id: id, path: "\(base)/\(base).E0\(i + 1).mkv", length: size))
            id += 1
        }
        files.append(TransferFile(id: id, path: "\(base)/Sample/\(base).sample.mkv", length: 24 * mb)); id += 1
        files.append(TransferFile(id: id, path: "\(base)/\(base).nfo", length: 3 * kb)); id += 1
        files.append(TransferFile(id: id, path: "\(base)/poster.jpg", length: 480 * kb)); id += 1

        let total = files.reduce(0) { $0 + $1.length }
        return (base, total, files)
    }

    // MARK: Events

    private nonisolated func emit(_ id: UUID, _ event: EngineEvent) {
        hub.emit(id, event)
    }

    // MARK: Supporting types

    /// Mutable per-task simulation bookkeeping.
    private struct SimState {
        var tick: Int = 0
        var metadataResolved: Bool = false
        var finishedEmitted: Bool = false
    }
}
