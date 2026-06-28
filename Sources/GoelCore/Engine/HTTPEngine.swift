import Foundation

/// The production HTTP download engine.
///
/// Backs every `.url` source. It performs **segmented** (multi-connection)
/// downloads by issuing parallel HTTP `Range` requests, writing each segment to
/// its own offset in a preallocated file, and emitting aggregate progress. When
/// the server cannot satisfy ranges — or omits a `Content-Length` — it falls
/// back to a single streaming connection. It detects range support, validates
/// resume cursors against `ETag`/`Last-Modified`, checks free disk space before
/// writing, and tears down `URLSession` work cleanly on pause/remove.
///
/// The engine is an `actor`, so all of its mutable bookkeeping is serialized and
/// it is `Sendable` for free. The synchronous `kind` requirement is satisfied by
/// a `nonisolated let`.
public actor HTTPEngine: DownloadEngine {

    // MARK: Identity

    public nonisolated let kind: DownloadKind = .http

    /// Lock-based fan-out of events to subscribers. Lives outside the actor's
    /// isolation so the synchronous `events(for:)` requirement can be satisfied
    /// by a `nonisolated` method.
    private nonisolated let hub = EventHub()

    // MARK: Dependencies

    private let session: URLSession

    /// The active traffic profile. Drives the per-server segment count.
    private var profile: TrafficProfile

    // MARK: Per-task state

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    /// Bytes completed per segment index (the live download cursor).
    private var segmentBytes: [UUID: [Int: Int64]] = [:]
    private var connections: [UUID: Int] = [:]
    private var meters: [UUID: Meter] = [:]
    private var cursorMeta: [UUID: CursorMeta] = [:]
    private var lastResumeEmit: [UUID: Date] = [:]

    /// Flush accumulated bytes to disk every 64 KiB. `static` so the
    /// `nonisolated` streaming path can read it without crossing actor isolation.
    private static let flushSize = 64 * 1024

    /// Hard sanity cap on a single download's declared size, to reject an
    /// absurd server `Content-Length` that would trigger a huge preallocation.
    static let maxDownloadSize: Int64 = 100 * 1024 * 1024 * 1024 // 100 GB

    // MARK: Init

    /// Inject a fully-configured `URLSession` (used by tests with a stub
    /// `URLProtocol`).
    public init(session: URLSession, profile: TrafficProfile = .high) {
        self.session = session
        self.profile = profile
    }

    /// Build a session from a configuration.
    public init(configuration: URLSessionConfiguration, profile: TrafficProfile = .high) {
        self.session = URLSession(configuration: configuration)
        self.profile = profile
    }

    /// Default real-world session.
    public init(profile: TrafficProfile = .high) {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.profile = profile
    }

    // MARK: DownloadEngine

    public func add(_ task: DownloadTask) async {
        guard tasks[task.id] == nil else { return }
        tasks[task.id] = task
        meters[task.id] = Meter()
        let id = task.id
        jobs[id] = Task { await self.run(id) }
    }

    public func pause(_ id: DownloadTask.ID) async {
        guard let job = jobs[id] else { return }
        job.cancel()
        jobs[id] = nil
        if let data = buildResumeData(id) {
            tasks[id]?.resumeData = data
            emit(id, .resumeDataUpdated(data))
        }
        tasks[id]?.status = .paused
        tasks[id]?.downloadSpeed = 0
        // Note: the manager owns the .paused transition (it called pause()). We do
        // NOT echo .statusChanged(.paused) — a stale echo arriving after a later
        // resume would wrongly flip the task back to paused and strand it.
    }

    public func resume(_ id: DownloadTask.ID) async {
        guard tasks[id] != nil, jobs[id] == nil else { return }
        meters[id] = Meter()
        emit(id, .statusChanged(.downloading))
        jobs[id] = Task { await self.run(id) }
    }

    public func remove(_ id: DownloadTask.ID, deleteData: Bool) async {
        let job = jobs[id]
        job?.cancel()
        jobs[id] = nil
        // Wait for the download task to actually unwind before deleting, so a
        // segment writer can't flush bytes to a path we've just unlinked.
        await job?.value
        if deleteData, let task = tasks[id], task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
        tasks[id] = nil
        segmentBytes[id] = nil
        meters[id] = nil
        connections[id] = nil
        cursorMeta[id] = nil
        lastResumeEmit[id] = nil
    }

    public func applyLimits(_ profile: TrafficProfile) async {
        self.profile = profile
    }

    public func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) async {
        guard var task = tasks[id] else { return }
        if let idx = task.files.firstIndex(where: { $0.id == fileID }) {
            task.files[idx].priority = priority
            tasks[id] = task
        }
    }

    public nonisolated func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        hub.subscribe(id)
    }

    // MARK: Driver

    private func run(_ id: UUID) async {
        guard let task = tasks[id], case .url(let url) = task.source else {
            let e = DownloadError.unknown("HTTPEngine requires a URL source")
            tasks[id]?.status = .failed(e)
            emit(id, .failed(e))
            emit(id, .statusChanged(.failed(e)))
            return
        }

        // Defense-in-depth: never write outside the save directory, even if a
        // hostile name slipped past upstream sanitisation.
        guard task.isSavePathContained else {
            let e = DownloadError.unknown("Path traversal blocked")
            tasks[id]?.status = .failed(e)
            jobs[id] = nil
            emit(id, .failed(e))
            emit(id, .statusChanged(.failed(e)))
            return
        }

        tasks[id]?.status = .downloading
        emit(id, .statusChanged(.downloading))

        do {
            try ensureDirectory(task.saveDirectory)
            let probe = try await probe(url)

            if let total = probe.totalBytes {
                try checkDiskSpace(task.saveDirectory, needed: total)
            }

            let fileURL = URL(fileURLWithPath: task.savePath)

            if let total = probe.totalBytes {
                tasks[id]?.totalBytes = total
                emit(id, .metadataResolved(
                    name: task.name,
                    totalBytes: total,
                    files: [TransferFile(id: 0, path: task.name, length: total)]
                ))
                if probe.acceptsRanges {
                    try await segmentedDownload(id: id, url: url, total: total, probe: probe, fileURL: fileURL)
                } else {
                    try await singleDownload(id: id, url: url, fileURL: fileURL)
                }
            } else {
                // No Content-Length: stream a single connection, leave totalBytes nil.
                try await singleDownload(id: id, url: url, fileURL: fileURL)
            }

            try Task.checkCancellation()

            forceProgress(id)
            tasks[id]?.status = .completed
            tasks[id]?.completedAt = Date()
            tasks[id]?.downloadSpeed = 0
            jobs[id] = nil
            emit(id, .finished)
            emit(id, .statusChanged(.completed))
        } catch is CancellationError {
            // Our own pause()/remove() cancelled the job; they publish the state.
        } catch {
            // Distinguish OUR cancellation (Task.isCancelled) from an EXTERNAL
            // URLSession cancel (VPN reset, OS preemption): the latter must not be
            // swallowed — it leaves the task stuck on "Downloading" forever.
            if Task.isCancelled { return }
            let de: DownloadError
            if let ue = error as? URLError, ue.code == .cancelled {
                de = .network("Connection reset")
            } else {
                de = mapError(error)
            }
            tasks[id]?.status = .failed(de)
            tasks[id]?.downloadSpeed = 0
            jobs[id] = nil
            emit(id, .failed(de))
            emit(id, .statusChanged(.failed(de)))
        }
    }

    // MARK: Range-support probe

    private struct ProbeResult {
        var totalBytes: Int64?
        var acceptsRanges: Bool
        var etag: String?
        var lastModified: String?
    }

    private func probe(_ url: URL) async throws -> ProbeResult {
        // Prefer a cheap HEAD.
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let (_, resp) = try? await session.data(for: head),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            let r = interpretHead(http)
            if r.totalBytes != nil { return r }
        }

        // Fall back to a one-byte ranged GET, which reveals both range support
        // (a 206 + Content-Range) and the total size.
        var get = URLRequest(url: url)
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, resp) = try await session.data(for: get)
        guard let http = resp as? HTTPURLResponse else {
            throw DownloadError.network("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        return interpretRangedGet(http)
    }

    private func interpretHead(_ http: HTTPURLResponse) -> ProbeResult {
        let acceptsRanges = (header(http, "Accept-Ranges")?.lowercased() == "bytes")
        let length = header(http, "Content-Length").flatMap { Int64($0) }
        return ProbeResult(
            totalBytes: length,
            acceptsRanges: acceptsRanges && length != nil,
            etag: header(http, "ETag"),
            lastModified: header(http, "Last-Modified")
        )
    }

    private func interpretRangedGet(_ http: HTTPURLResponse) -> ProbeResult {
        let etag = header(http, "ETag")
        let lastModified = header(http, "Last-Modified")

        if http.statusCode == 206 {
            // "bytes 0-0/12345" -> 12345
            let total = header(http, "Content-Range")
                .flatMap { $0.split(separator: "/").last }
                .flatMap { Int64($0) }
            return ProbeResult(totalBytes: total, acceptsRanges: total != nil, etag: etag, lastModified: lastModified)
        }

        // Server ignored the Range header and returned the whole body.
        let length = header(http, "Content-Length").flatMap { Int64($0) }
        return ProbeResult(totalBytes: length, acceptsRanges: false, etag: etag, lastModified: lastModified)
    }

    private func header(_ http: HTTPURLResponse, _ name: String) -> String? {
        http.value(forHTTPHeaderField: name)
    }

    // MARK: Segmented download

    private func segmentedDownload(id: UUID, url: URL, total: Int64, probe: ProbeResult, fileURL: URL) async throws {
        var ranges: [Range64]
        var restored: [Int: Int64] = [:]

        if let data = tasks[id]?.resumeData,
           let cursor = try? JSONDecoder().decode(ResumeCursor.self, from: data),
           cursor.totalBytes == total,
           validatorsMatch(cursor, probe) {
            // Remote unchanged: continue from where we left off.
            ranges = cursor.ranges
            for (i, done) in cursor.completed.enumerated() { restored[i] = done }
            try preallocate(fileURL, size: total)
        } else {
            // Fresh start (or remote changed): rebuild from scratch.
            let count = computeSegmentCount(total)
            ranges = makeRanges(total: total, count: count)
            try preallocate(fileURL, size: total)
        }

        segmentBytes[id] = restored.isEmpty
            ? Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, Int64(0)) })
            : restored
        connections[id] = ranges.count
        tasks[id]?.connectionCount = ranges.count
        cursorMeta[id] = CursorMeta(etag: probe.etag, lastModified: probe.lastModified, total: total, ranges: ranges)

        let session = self.session
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, range) in ranges.enumerated() {
                let already = segmentBytes[id]?[i] ?? 0
                let segStart = range.start + already
                if segStart > range.end { continue } // segment already complete
                group.addTask {
                    try await self.downloadSegment(session: session, id: id, url: url, index: i, from: segStart, to: range.end, fileURL: fileURL)
                }
            }
            try await group.waitForAll()
        }
    }

    /// `nonisolated` so the byte pump runs OFF the actor — otherwise every segment
    /// would serialize through the actor executor (one hop per byte), defeating the
    /// whole point of segmented downloading. It only hops back to the actor (via
    /// `await advance`) once per ~64 KiB flush.
    private nonisolated func downloadSegment(session: URLSession, id: UUID, url: URL, index: Int, from start: Int64, to end: Int64, fileURL: URL) async throws {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DownloadError.network("No HTTP response") }
        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw DownloadError.httpStatus(http.statusCode)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            try handle.seek(toOffset: UInt64(start))
            var buffer = Data()
            buffer.reserveCapacity(Self.flushSize)
            // Cooperative cancellation flows from the AsyncBytes iterator, so we
            // check once per flush rather than once per byte (the latter burns
            // ~16% of a core at speed for no added safety).
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.flushSize {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    await advance(id, segment: index, by: buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                await advance(id, segment: index, by: buffer.count)
            }
            // Close explicitly so a flush/close failure propagates and fails the
            // task, instead of reporting `.completed` over a half-flushed file.
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    // MARK: Single-connection download

    private func singleDownload(id: UUID, url: URL, fileURL: URL) async throws {
        // SF8: truncate to zero on (re)create — `createFile` is a no-op when the
        // file already exists, which would leave stale trailing bytes if the new
        // download is shorter. `Data().write` both creates and truncates.
        try Data().write(to: fileURL)

        segmentBytes[id] = [0: 0]
        connections[id] = 1
        tasks[id]?.connectionCount = 1
        cursorMeta[id] = nil

        try await streamSingle(session: session, id: id, url: url, fileURL: fileURL)
    }

    /// `nonisolated` single-connection body pump (see ``downloadSegment`` for why).
    private nonisolated func streamSingle(session: URLSession, id: UUID, url: URL, fileURL: URL) async throws {
        let req = URLRequest(url: url)
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DownloadError.network("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw DownloadError.httpStatus(http.statusCode) }

        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            var buffer = Data()
            buffer.reserveCapacity(Self.flushSize)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.flushSize {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    await advance(id, segment: 0, by: buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                await advance(id, segment: 0, by: buffer.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    // MARK: Segmenting

    private func computeSegmentCount(_ total: Int64) -> Int {
        let want = max(1, profile.maxConnectionsPerServer)
        let minSegment: Int64 = 64 * 1024
        let bySize = max(1, Int((total + minSegment - 1) / minSegment))
        return max(1, min(want, bySize))
    }

    private func makeRanges(total: Int64, count: Int) -> [Range64] {
        guard total > 0 else { return [] }            // zero-byte file: nothing to fetch
        guard count > 0 else { return [Range64(start: 0, end: total - 1)] }
        let base = total / Int64(count)
        var ranges: [Range64] = []
        var start: Int64 = 0
        for i in 0..<count {
            let end = (i == count - 1) ? total - 1 : start + base - 1
            ranges.append(Range64(start: start, end: end))
            start = end + 1
        }
        return ranges
    }

    // MARK: Progress

    private func advance(_ id: UUID, segment: Int, by n: Int) {
        guard tasks[id] != nil else { return }
        segmentBytes[id, default: [:]][segment, default: 0] += Int64(n)
        recordAndEmit(id)
    }

    private func recordAndEmit(_ id: UUID) {
        guard tasks[id] != nil else { return }
        let total = segmentBytes[id]?.values.reduce(0, +) ?? 0
        tasks[id]?.bytesDownloaded = total

        let now = Date()
        var meter = meters[id] ?? Meter()
        guard now.timeIntervalSince(meter.lastEmit) > 0.1 else { return }

        // O(1) two-point sliding window: speed since the previous emit. No growing
        // sample array to scan/trim on every flush.
        let dt = now.timeIntervalSince(meter.lastEmit)
        let speed = (dt > 0 && dt < 3600) ? Double(total - meter.lastEmitBytes) / dt : 0
        meter.lastEmit = now
        meter.lastEmitBytes = total
        meters[id] = meter

        tasks[id]?.downloadSpeed = speed
        emit(id, .progress(
            bytesDownloaded: total,
            bytesUploaded: 0,
            downloadSpeed: speed,
            uploadSpeed: 0,
            connectionCount: connections[id] ?? 1
        ))
        emit(id, .fileProgress(fileID: 0, bytesCompleted: total))
        maybeEmitResume(id, now: now)
    }

    private func forceProgress(_ id: UUID) {
        if meters[id] == nil { meters[id] = Meter() }
        meters[id]?.lastEmit = .distantPast
        recordAndEmit(id)
    }

    // MARK: Resume cursor

    private func maybeEmitResume(_ id: UUID, now: Date) {
        guard cursorMeta[id] != nil else { return }
        if now.timeIntervalSince(lastResumeEmit[id] ?? .distantPast) < 1.0 { return }
        lastResumeEmit[id] = now
        if let data = buildResumeData(id) {
            tasks[id]?.resumeData = data
            emit(id, .resumeDataUpdated(data))
        }
    }

    private func buildResumeData(_ id: UUID) -> Data? {
        guard let meta = cursorMeta[id] else { return nil }
        let completed = meta.ranges.indices.map { segmentBytes[id]?[$0] ?? 0 }
        let cursor = ResumeCursor(
            etag: meta.etag,
            lastModified: meta.lastModified,
            totalBytes: meta.total,
            ranges: meta.ranges,
            completed: completed
        )
        return try? JSONEncoder().encode(cursor)
    }

    private func validatorsMatch(_ cursor: ResumeCursor, _ probe: ProbeResult) -> Bool {
        Self.validatorsAllowResume(
            cursorETag: cursor.etag, cursorLastModified: cursor.lastModified,
            probeETag: probe.etag, probeLastModified: probe.lastModified
        )
    }

    /// Pure, testable resume-validation gate. If neither side offers an `ETag`
    /// nor a `Last-Modified`, there is nothing to verify the remote file is
    /// unchanged — so we DO NOT resume (a silent swap would corrupt the file);
    /// we restart from scratch instead.
    static func validatorsAllowResume(
        cursorETag: String?, cursorLastModified: String?,
        probeETag: String?, probeLastModified: String?
    ) -> Bool {
        if let a = cursorETag, let b = probeETag { return a == b }
        if let a = cursorLastModified, let b = probeLastModified { return a == b }
        return false
    }

    // MARK: Disk / filesystem

    private func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func checkDiskSpace(_ directory: String, needed: Int64) throws {
        try Self.validateDiskSpace(directory: directory, needed: needed)
    }

    /// Pure, testable disk-space gate. Rejects absurd sizes (cap), and — crucially
    /// — THROWS when the volume can't be queried instead of silently assuming
    /// unlimited space (which bypassed the guard entirely and let a multi-GB
    /// download start against a full disk).
    static func validateDiskSpace(
        directory: String,
        needed: Int64,
        maxAllowed: Int64 = HTTPEngine.maxDownloadSize
    ) throws {
        guard needed <= maxAllowed else {
            throw DownloadError.unknown("Declared size \(needed.byteString) exceeds the maximum allowed (\(maxAllowed.byteString))")
        }
        let url = URL(fileURLWithPath: directory)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw DownloadError.diskFull(needed: needed, available: 0)
        }
        if needed > available {
            throw DownloadError.diskFull(needed: needed, available: available)
        }
    }

    private func preallocate(_ url: URL, size: Int64) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    // MARK: Errors / events

    private func mapError(_ error: Error) -> DownloadError {
        if let de = error as? DownloadError { return de }
        if let ue = error as? URLError {
            switch ue.code {
            case .timedOut: return .timedOut
            case .cancelled: return .canceled
            case .fileDoesNotExist: return .fileMissing
            default: return .network(ue.localizedDescription)
            }
        }
        return .network((error as NSError).localizedDescription)
    }

    private nonisolated func emit(_ id: UUID, _ event: EngineEvent) {
        hub.emit(id, event)
    }

    // MARK: Supporting types

    /// Two-point speed window: the time and byte-count at the previous emit.
    private struct Meter {
        var lastEmit: Date = .distantPast
        var lastEmitBytes: Int64 = 0
    }

    private struct Range64: Codable, Sendable {
        var start: Int64
        var end: Int64
    }

    private struct CursorMeta {
        var etag: String?
        var lastModified: String?
        var total: Int64
        var ranges: [Range64]
    }

    private struct ResumeCursor: Codable, Sendable {
        var etag: String?
        var lastModified: String?
        var totalBytes: Int64
        var ranges: [Range64]
        var completed: [Int64]
    }
}

/// Thread-safe broadcaster of `EngineEvent`s to per-task subscribers.
///
/// Held by `HTTPEngine` as a `nonisolated let` so both the synchronous
/// `events(for:)` and the actor-internal `emit` can reach it without crossing
/// isolation boundaries.
private final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: [UUID: AsyncStream<EngineEvent>.Continuation]] = [:]

    func subscribe(_ id: UUID) -> AsyncStream<EngineEvent> {
        // Unbounded is required: this stream also carries NON-idempotent lifecycle
        // events (statusChanged / metadataResolved / finished / failed) that must
        // never be dropped — a dropped `.downloading` after a resume would strand
        // the task. Memory is bounded instead by throttling progress emission at
        // the source (HTTP emits at ~10 Hz; the manager consumes promptly).
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .unbounded)
        let subID = UUID()
        lock.lock()
        subscribers[id, default: [:]][subID] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.subscribers[id]?[subID] = nil
            self.lock.unlock()
        }
        return stream
    }

    func emit(_ id: UUID, _ event: EngineEvent) {
        lock.lock()
        let continuations = subscribers[id]?.values.map { $0} ?? []
        lock.unlock()
        for continuation in continuations { continuation.yield(event) }
    }

    func finishAll(_ id: UUID) {
        lock.lock()
        let continuations = subscribers[id]
        subscribers[id] = nil
        lock.unlock()
        continuations?.values.forEach { $0.finish() }
    }
}
