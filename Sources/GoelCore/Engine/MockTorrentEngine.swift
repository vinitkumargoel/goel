import Foundation

actor MockTorrentEngine: TorrentControlling {
    public nonisolated let kind: DownloadKind = .torrent

    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata, .perFilePriority] }

    /// Must stay outside actor isolation: `events(for:)` is a synchronous `nonisolated` requirement.
    private nonisolated let hub = EventHub()

    struct Simulation: Sendable, Hashable {
        var tickInterval: TimeInterval
        var bytesPerTick: Int64
        var uploadBytesPerTick: Int64
        var metadataDelayTicks: Int
        var minPeers: Int
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

        static let demo = Simulation()
    }

    private let sim: Simulation

    private var profile: TrafficProfile

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var states: [UUID: SimState] = [:]

    /// Progress beats are throttled (lifecycle beats are not): a fast sim would back the stream up.
    private var lastProgressEmit: [UUID: Date] = [:]
    private static let progressEmitInterval: TimeInterval = 0.08

    init(simulation: Simulation = .demo, profile: TrafficProfile = .high) {
        self.sim = simulation
        self.profile = profile
    }

    func add(_ task: DownloadTask) async {
        guard tasks[task.id] == nil else { return }
        tasks[task.id] = task
        // Seed from persisted progress, or a disk-restored torrent replays phases it already finished.
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
        tasks[id]?.connectionCount = 0
        // Never echo .statusChanged(.paused): a stale one landing after a resume strands the task.
    }

    func resume(_ id: DownloadTask.ID) async {
        guard tasks[id] != nil, jobs[id] == nil else { return }
        if states[id] == nil { states[id] = SimState() }
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

    func applySessionConfig(_ config: TorrentSessionConfig) async {}

    func configure(_ session: TorrentSessionConfig) async {
        await applySessionConfig(session)
    }

    func setSequential(_ sequential: Bool, task id: DownloadTask.ID) async {
        tasks[id]?.sequentialDownload = sequential
    }

    func setUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) async {
        tasks[id]?.uploadLimitBytesPerSec = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
    }
    func setSeedRatioLimit(_ ratio: Double?, task id: DownloadTask.ID) async {
        tasks[id]?.seedRatioLimit = (ratio ?? 0) > 0 ? ratio : nil
    }
    func forceRecheck(_ id: DownloadTask.ID) async {}
    func forceReannounce(_ id: DownloadTask.ID) async {}

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        let meta = Self.synthesizeMetadata(name: "")
        return EngineMetadata(name: meta.name, totalBytes: meta.total, files: meta.files)
    }

    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) async {
        guard var task = tasks[id] else { return }
        guard let idx = task.files.firstIndex(where: { $0.id == fileID }) else { return }
        task.files[idx].priority = priority
        tasks[id] = task

        // Un-skipping adds bytes after the download gate closed, and the seeding loop never re-checks it.
        guard priority != .skip,
              wantedRemaining(id) > 0,
              tasks[id]?.status != .paused
        else { return }
        jobs[id]?.cancel()
        jobs[id] = nil
        states[id]?.finishedEmitted = false
        jobs[id] = Task { await self.run(id) }
    }

    nonisolated func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        hub.subscribe(id)
    }

    func snapshot(_ id: DownloadTask.ID) -> DownloadTask? {
        tasks[id]
    }

    private func run(_ id: UUID) async {
        guard tasks[id] != nil else { return }
        if states[id] == nil { states[id] = SimState() }

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

        if !downloadComplete(id) {
            tasks[id]?.status = .downloading
            emit(id, .statusChanged(.downloading))
            while !downloadComplete(id) {
                do { try await tick(id) } catch { return }
                applyDownloadTick(id)
            }
        }

        if states[id]?.finishedEmitted == false {
            finalizeDownload(id)
            states[id]?.finishedEmitted = true
            emit(id, .finished)
            tasks[id]?.status = .seeding
            tasks[id]?.downloadSpeed = 0
            emit(id, .statusChanged(.seeding))
        }

        if !seedRatioReached(id) {
            if tasks[id]?.status != .seeding {
                tasks[id]?.status = .seeding
                emit(id, .statusChanged(.seeding))
            }
            while !seedRatioReached(id) {
                do { try await tick(id) } catch { return }
                applySeedTick(id)
            }
        }

        guard tasks[id] != nil else { return }
        tasks[id]?.status = .completed
        tasks[id]?.completedAt = Date()
        tasks[id]?.downloadSpeed = 0
        tasks[id]?.uploadSpeed = 0
        tasks[id]?.connectionCount = 0
        jobs[id] = nil
        emit(id, .statusChanged(.completed))
    }

    private func tick(_ id: UUID) async throws {
        if sim.tickInterval > 0 {
            try await Task.sleep(nanoseconds: UInt64((sim.tickInterval * 1_000_000_000).rounded()))
        } else {
            await Task.yield()
        }
        try Task.checkCancellation()
        states[id]?.tick += 1
    }

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
        let limit = task.seedRatioLimit ?? profile.seedRatioLimit
        if limit <= 0 { return true }
        if task.bytesDownloaded <= 0 { return true }
        return task.shareRatio >= limit
    }

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
        // Floor at 1: a `perTick` truncated to 0 stalls shareRatio and the seed phase loops forever.
        return max(1, min(base, perTick))
    }

    private func speed(_ bytesThisTick: Int64) -> Double {
        guard bytesThisTick > 0 else { return 0 }
        if sim.tickInterval > 0 { return Double(bytesThisTick) / sim.tickInterval }
        return Double(bytesThisTick) * 60
    }

    private func peerCount(_ id: UUID) -> Int {
        let t = states[id]?.tick ?? 0
        let lo = max(0, sim.minPeers)
        let hi = max(lo, sim.maxPeers)
        let span = hi - lo
        let raw = span == 0 ? lo : lo + ((t * 7 + 3) % (span + 1))
        let maxConn = profile.maxConnections > 0 ? profile.maxConnections : Int.max
        return min(raw, maxConn)
    }

    private func resolveMetadata(for task: DownloadTask) -> (name: String, total: Int64, files: [TransferFile]) {
        if !task.files.isEmpty {
            let total = task.totalBytes ?? task.files.reduce(0) { $0 + $1.length }
            return (task.name, total, task.files)
        }
        return Self.synthesizeMetadata(name: task.name)
    }

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

    private nonisolated func emit(_ id: UUID, _ event: EngineEvent) {
        hub.emit(id, event)
    }

    private struct SimState {
        var tick: Int = 0
        var metadataResolved: Bool = false
        var finishedEmitted: Bool = false
    }
}
