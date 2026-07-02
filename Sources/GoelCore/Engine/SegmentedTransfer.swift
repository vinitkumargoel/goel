import Foundation

// MARK: - Segmented transfer

/// The per-download transfer engine, extracted from ``HTTPEngine`` so the byte
/// mechanics are directly unit-testable without the actor's task lifecycle.
///
/// It moves the bytes of a single download: segmented (multi-connection) when the
/// server supports ranges and the total size is known, or a single streaming
/// connection otherwise. Segments are written to their own offset in a
/// preallocated file; a per-download ``ConnectionGovernor`` adapts the fan-out to
/// the server's real concurrency ceiling and a shared ``RateLimiter`` paces the
/// aggregate throughput. Resume cursors are validated against `ETag` /
/// `Last-Modified` so a changed remote restarts rather than corrupts.
///
/// It owns NO cross-download state: the global / per-host connection budget and
/// task bookkeeping stay on ``HTTPEngine``, which resolves ``TransferPlan/segmentCount``
/// from that budget before handing a plan here. The byte pumps run off any actor
/// (this is a plain `Sendable` class, not an actor) and hop to an internal ledger
/// actor only once per flush — to accumulate per-segment bytes, build the resume
/// cursor and throttle progress — keeping the hot path off the executor.
final class SegmentedTransfer: Sendable {

    let plan: TransferPlan

    /// Live progress ticks. Consumed by ``HTTPEngine`` to update its task and
    /// re-emit `EngineEvent`s. Finishes when ``run()`` returns or throws.
    let progress: AsyncStream<TransferProgress>
    private let continuation: AsyncStream<TransferProgress>.Continuation

    /// Whether this download fans out into ranged segments (vs a single stream).
    private let segmented: Bool
    /// The exact segment ranges the run will use — resume-restored or freshly cut.
    private let plannedRanges: [Range64]
    /// Bytes already on disk per segment index when resuming; empty otherwise.
    private let restoredBytes: [Int: Int64]

    /// The number of connections this transfer will open. ``HTTPEngine`` reserves
    /// this against the cross-download budget so the reservation matches the real
    /// fan-out on both the fresh and the resume path (a restored cursor may carry a
    /// different range count than the freshly-resolved ``TransferPlan/segmentCount``).
    /// Single-stream transfers use one connection.
    var connectionCount: Int { segmented ? plannedRanges.count : 1 }

    init(plan: TransferPlan) {
        self.plan = plan
        var cont: AsyncStream<TransferProgress>.Continuation!
        self.progress = AsyncStream<TransferProgress> { cont = $0 }
        self.continuation = cont

        // Resolve segmented-vs-single and the segment layout up front. Everything
        // here is pure (cursor decode + validation + range math) so the caller can
        // reserve the matching `connectionCount` before `run()`; the file I/O
        // (preallocate) stays in `run()`.
        guard let total = plan.totalBytes, plan.acceptsRanges else {
            self.segmented = false
            self.plannedRanges = []
            self.restoredBytes = [:]
            return
        }
        if let data = plan.existingResume,
           let cursor = try? JSONDecoder().decode(ResumeCursor.self, from: data),
           cursor.totalBytes == total,
           Self.cursorIsWellFormed(cursor, total: total),
           Self.validatorsAllowResume(
                cursorETag: cursor.etag, cursorLastModified: cursor.lastModified,
                probeETag: plan.etag, probeLastModified: plan.lastModified) {
            // Remote unchanged and cursor sound: continue from where we left off.
            self.segmented = true
            self.plannedRanges = cursor.ranges
            self.restoredBytes = Dictionary(
                uniqueKeysWithValues: cursor.completed.enumerated().map { ($0.offset, $0.element) })
        } else {
            // Fresh start (or remote changed / cursor unusable): rebuild from scratch.
            self.segmented = true
            self.plannedRanges = Self.makeRanges(
                total: total, count: Self.clampSegmentCount(plan.segmentCount, total: total))
            self.restoredBytes = [:]
        }
    }

    // MARK: Entry point

    /// Run the transfer to completion. Chooses single-stream vs segmented purely
    /// from the plan's flags (no total size or no range support -> single). The
    /// progress stream is always finished on exit so a consumer's `for await`
    /// terminates whether we complete, fail, or are cancelled.
    func run() async throws -> TransferOutcome {
        defer { continuation.finish() }
        guard segmented else { return try await runSingle() }
        return try await runSegmented(total: plan.totalBytes!)
    }

    // MARK: Segmented download

    private func runSegmented(total: Int64) async throws -> TransferOutcome {
        // The shape (resume-continue vs fresh) and `ranges` were resolved in
        // `init` so the caller could reserve the matching connection count; here
        // we just realise the file and move bytes.
        let ranges = plannedRanges
        try Self.preallocate(plan.destination, size: total)

        let initialBytes = restoredBytes.isEmpty
            ? Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, Int64(0)) })
            : restoredBytes
        let meta = CursorMeta(etag: plan.etag, lastModified: plan.lastModified, total: total, ranges: ranges)
        let ledger = Ledger(continuation: continuation, meta: meta,
                            initialSegmentBytes: initialBytes, connectionCount: ranges.count)

        let limiter = plan.maxBytesPerSecond > 0 ? RateLimiter(bytesPerSecond: plan.maxBytesPerSecond) : nil
        let session = plan.session
        // One governor per download: it begins at the requested fan-out and
        // adapts down to the server's real concurrent-connection ceiling.
        let governor = ConnectionGovernor(limit: ranges.count)
        // Segments spread across the primary + mirrors round-robin; a mirror
        // that misbehaves is demoted and its segment retries elsewhere.
        let pool = MirrorPool(primary: plan.url, mirrors: plan.mirrors)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, range) in ranges.enumerated() {
                let already = initialBytes[i] ?? 0
                let segStart = range.start + already
                if segStart > range.end { continue } // segment already complete
                group.addTask {
                    try await self.downloadSegment(session: session, governor: governor, limiter: limiter,
                                                   ledger: ledger, pool: pool, index: i,
                                                   from: segStart, to: range.end, fileURL: self.plan.destination)
                }
            }
            try await group.waitForAll()
        }

        let bytesWritten = await ledger.totalBytes()
        let resumeData = await ledger.currentResumeData()
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: resumeData, usedSegments: ranges.count)
    }

    /// The byte pump runs OFF any actor (this is a plain class) — otherwise every
    /// segment would serialize through an executor (one hop per byte), defeating
    /// the whole point of segmented downloading. It hops to the ledger actor (via
    /// `await ledger.advance`) only once per ~`flushSize` flush.
    private func downloadSegment(session: URLSession, governor: ConnectionGovernor, limiter: RateLimiter?,
                                 ledger: Ledger, pool: MirrorPool, index: Int,
                                 from start: Int64, to end: Int64, fileURL: URL) async throws {
        let settings = plan.settings
        let flushSize = plan.flushSize
        let handle = try FileHandle(forWritingTo: fileURL)
        // Bytes of THIS segment already flushed to disk in this run. On a retry
        // we resume from `start + written`, so progress is never double-counted
        // and already-stored bytes are not re-fetched.
        var written: Int64 = 0
        var attempt = 0
        // Holds the request currently in flight so the cancellation handler can
        // abort the underlying URLSession task (pause/remove), not merely the
        // Swift task — the delegate-driven body would otherwise keep draining.
        let streamerBox = StreamerBox()
        do {
            try await withTaskCancellationHandler {
                while start + written <= end {
                    try Task.checkCancellation()
                    attempt += 1
                    let segStart = start + written
                    let url = await pool.url(segment: index, attempt: attempt)
                    let isMirror = url != plan.url

                    // Wait for a connection slot. The governor adapts the ceiling to
                    // what the server actually tolerates (see ``ConnectionGovernor``).
                    // Each `acquire()` below is balanced by exactly one `release()` on
                    // every exit path of this attempt.
                    await governor.acquire()
                    var req = request(for: url)
                    req.setValue("bytes=\(segStart)-\(end)", forHTTPHeaderField: "Range")

                    let bytes: AsyncThrowingStream<Data, Error>
                    let http: HTTPURLResponse
                    let streamer: ChunkStreamer
                    do {
                        (http, bytes, streamer) = try await Self.openStream(
                            session: session, request: req) { streamerBox.set($0) }
                    } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
                        if isMirror { await pool.demote(url) }
                        await governor.release()
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    } catch {
                        await governor.release(); throw error
                    }

                    if Self.isRetryableStatus(http.statusCode) {
                        streamer.cancelTask()                            // stop the error body
                        if isMirror { await pool.demote(url) }
                        await governor.throttleDown()                    // server pushed back: shrink the ceiling
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.httpStatus(http.statusCode) }
                        try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                        continue
                    }
                    // Segments accept ONLY 206. A server that advertised range support
                    // but answers a real ranged GET with 200 (full body) would have
                    // every segment seek to its own offset and write the WHOLE file
                    // there, overwriting siblings and corrupting the result. A mirror
                    // that can't do ranges is demoted; the primary fails visibly.
                    guard http.statusCode == 206 else {
                        streamer.cancelTask()
                        await governor.release()
                        if isMirror, attempt < settings.maxAttempts {
                            await pool.demote(url)
                            continue
                        }
                        throw DownloadError.httpStatus(http.statusCode)
                    }
                    // A mirror must be serving the same representation: its 206 has
                    // to describe the same total size. Divergent mirrors are demoted
                    // and the segment retries elsewhere (the wrong body is cancelled).
                    if isMirror, let expected = plan.totalBytes,
                       Self.contentRangeTotal(http) != expected {
                        streamer.cancelTask()
                        await pool.demote(url)
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.remoteFileChanged }
                        continue
                    }

                    do {
                        try handle.seek(toOffset: UInt64(segStart))
                        var buffer = Data()
                        buffer.reserveCapacity(flushSize)
                        // Body arrives as `Data` chunks from the task delegate (not
                        // one byte per `await`), so appends are memcpys and the loop
                        // isn't CPU-bound. `consumed` releases backpressure credit as
                        // each chunk leaves the stream; cancellation is checked once
                        // per flush (cheap, and cancelling aborts the URLSession task).
                        for try await chunk in bytes {
                            buffer.append(chunk)
                            streamer.consumed(chunk.count)
                            if buffer.count >= flushSize {
                                try Task.checkCancellation()
                                try handle.write(contentsOf: buffer)
                                written += Int64(buffer.count)
                                await ledger.advance(segment: index, by: buffer.count)
                                // Pace against the profile's aggregate download cap.
                                // Shared across all segments, so combined throughput
                                // converges on the cap (no-op when unlimited).
                                await limiter?.pace(buffer.count)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        try Task.checkCancellation()
                        if !buffer.isEmpty {
                            try handle.write(contentsOf: buffer)
                            written += Int64(buffer.count)
                            await ledger.advance(segment: index, by: buffer.count)
                            await limiter?.pace(buffer.count)
                        }
                    } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
                        // Connection dropped mid-stream: back off and resume from the
                        // last flushed offset (on another mirror if this one flaked).
                        streamer.cancelTask()
                        if isMirror { await pool.demote(url) }
                        await governor.release()
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    } catch {
                        streamer.cancelTask()
                        await governor.release(); throw error
                    }

                    await governor.release()
                    break                                                // segment complete
                }
            } onCancel: {
                streamerBox.cancel()
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

    private func runSingle() async throws -> TransferOutcome {
        // SF8: truncate to zero on (re)create — `createFile` is a no-op when the
        // file already exists, which would leave stale trailing bytes if the new
        // download is shorter. `Data().write` both creates and truncates.
        try Data().write(to: plan.destination)

        let ledger = Ledger(continuation: continuation, meta: nil,
                            initialSegmentBytes: [0: 0], connectionCount: 1)
        let limiter = plan.maxBytesPerSecond > 0 ? RateLimiter(bytesPerSecond: plan.maxBytesPerSecond) : nil

        try await streamSingle(session: plan.session, limiter: limiter, ledger: ledger,
                               url: plan.url, fileURL: plan.destination)

        let bytesWritten = await ledger.totalBytes()
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: nil, usedSegments: 1)
    }

    /// Single-connection body pump (see ``downloadSegment`` for why it runs off
    /// the actor).
    private func streamSingle(session: URLSession, limiter: RateLimiter?, ledger: Ledger,
                              url: URL, fileURL: URL) async throws {
        let settings = plan.settings
        let flushSize = plan.flushSize
        let streamerBox = StreamerBox()
        try await withTaskCancellationHandler {
            // Retry only the connect/status phase: the no-range fallback can't
            // resume a partial body, so a mid-stream drop is terminal (the body
            // read below is deliberately outside this retry loop, so it never
            // silently restarts and double-counts progress).
            var result: (HTTPURLResponse, AsyncThrowingStream<Data, Error>, ChunkStreamer)?
            var attempt = 0
            while true {
                try Task.checkCancellation()
                attempt += 1
                let req = Self.makeRequest(url, settings: settings)
                do {
                    let opened = try await Self.openStream(
                        session: session, request: req) { streamerBox.set($0) }
                    if Self.isRetryableStatus(opened.0.statusCode), attempt < settings.maxAttempts {
                        opened.2.cancelTask()                        // drop the error body
                        try await backoff(attempt: attempt, response: opened.0, retryInterval: settings.retryInterval)
                        continue
                    }
                    guard (200..<300).contains(opened.0.statusCode) else {
                        opened.2.cancelTask()
                        throw DownloadError.httpStatus(opened.0.statusCode)
                    }
                    result = opened
                    break
                } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
                    try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                    continue
                }
            }
            // The loop exits only via `break` (result assigned) or by throwing.
            guard let (_, bytes, streamer) = result else { return }

            let handle = try FileHandle(forWritingTo: fileURL)
            do {
                var buffer = Data()
                buffer.reserveCapacity(flushSize)
                for try await chunk in bytes {
                    buffer.append(chunk)
                    streamer.consumed(chunk.count)
                    if buffer.count >= flushSize {
                        try Task.checkCancellation()
                        try handle.write(contentsOf: buffer)
                        await ledger.advance(segment: 0, by: buffer.count)
                        // Pace against the profile's download cap (no-op when unlimited).
                        await limiter?.pace(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                    await ledger.advance(segment: 0, by: buffer.count)
                    await limiter?.pace(buffer.count)
                }
                try handle.close()
            } catch {
                streamer.cancelTask()
                try? handle.close()
                throw error
            }
        } onCancel: {
            streamerBox.cancel()
        }
    }

    // MARK: Range math

    /// Clamp the caller-resolved (budget-derived) segment count by file size: a
    /// tiny file never gets more segments than 64 KiB chunks. The cross-download
    /// connection budget is applied by ``HTTPEngine`` before it sets
    /// ``TransferPlan/segmentCount``; this is the size-only half of the decision.
    func computeSegmentCount(_ total: Int64) -> Int {
        Self.clampSegmentCount(plan.segmentCount, total: total)
    }

    /// The size-only clamp, factored out as `static` so ``init`` can resolve the
    /// fan-out before any instance method is available.
    static func clampSegmentCount(_ requested: Int, total: Int64) -> Int {
        let minSegment: Int64 = 64 * 1024
        let bySize = max(1, Int((total + minSegment - 1) / minSegment))
        return max(1, min(requested, bySize))
    }

    static func makeRanges(total: Int64, count: Int) -> [Range64] {
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

    // MARK: Request building & retry policy

    /// Builds a request carrying the client `User-Agent` (and the preemptive
    /// `Authorization` header for protected hosts). All outbound requests must
    /// go through here so none are sent UA-less (a missing UA causes some
    /// CDNs / WAFs to reset the connection, surfacing as -1005).
    static func makeRequest(_ url: URL, settings: RequestSettings) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(settings.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in settings.extraHeaders {
            req.setValue(value, forHTTPHeaderField: name)
        }
        if let auth = settings.authorization {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let referer = settings.referer {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return req
    }

    /// A request for any pool URL. The stored `Authorization` was resolved for
    /// the PRIMARY host — it must never ride to a mirror on a different host
    /// (that would hand the user's credentials to whoever runs the mirror).
    private func request(for url: URL) -> URLRequest {
        var settings = plan.settings
        // The Authorization / Referer / custom headers were resolved for the
        // PRIMARY host — none of them may ride to a mirror on a different host
        // (that would leak the user's credentials/context to the mirror operator).
        if url.host?.lowercased() != plan.url.host?.lowercased() {
            settings.authorization = nil
            settings.referer = nil
            settings.extraHeaders = [:]
        }
        return Self.makeRequest(url, settings: settings)
    }

    /// Open `request` and return its response headers together with a stream of
    /// body `Data` chunks and the ``ChunkStreamer`` driving it. This replaces
    /// `URLSession.bytes(for:)`, whose one-byte-per-`await` iteration is
    /// CPU-bound and caps throughput on fast links: a delegate delivers large
    /// `Data` chunks with no per-byte overhead, and the streamer applies TCP
    /// backpressure (suspending the task when the consumer falls behind).
    ///
    /// `register` runs synchronously with the streamer *before* the task starts,
    /// so a task-cancellation handler that captured the box can abort even during
    /// the initial connect. The awaited response resolves on the first response
    /// header (or throws if the task fails before one arrives).
    static func openStream(
        session: URLSession, request: URLRequest,
        register: (ChunkStreamer) -> Void
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, ChunkStreamer) {
        let streamer = ChunkStreamer()
        var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        let body = AsyncThrowingStream<Data, Error> { bodyContinuation = $0 }
        let task = session.dataTask(with: request)
        task.delegate = streamer
        streamer.prepare(body: bodyContinuation, task: task)
        register(streamer)
        let response: HTTPURLResponse = try await withCheckedThrowingContinuation { cont in
            streamer.setResponseContinuation(cont)
            task.resume()
        }
        return (response, body, streamer)
    }

    /// The total-size suffix of a 206's `Content-Range` ("bytes 0-99/12345").
    static func contentRangeTotal(_ http: HTTPURLResponse) -> Int64? {
        http.value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last.flatMap { Int64($0) }
    }

    /// HTTP statuses worth retrying: explicit rate-limiting plus transient
    /// upstream/server errors.
    static func isRetryableStatus(_ status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    /// Network-level errors that a retry can plausibly recover from (a dropped
    /// connection, a timeout, a refused/transient host). Deliberately excludes
    /// `.cancelled` (our own pause/remove) and non-network errors (disk, etc.).
    static func isTransient(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Sleeps before the next attempt: honours a numeric `Retry-After` header
    /// when present, otherwise exponential backoff. Jitter de-synchronises a
    /// burst of segments that were all rate-limited at once (thundering herd).
    /// `Task.sleep` throws on cancellation, so pause/remove still interrupt.
    private func backoff(attempt: Int, response: HTTPURLResponse?, retryInterval: Double) async throws {
        var seconds = min(6.0, pow(2.0, Double(attempt - 1)) * 0.4)
        // A configured retry interval acts as a floor on the wait (0 = leave the
        // built-in exponential backoff untouched).
        if retryInterval > 0 { seconds = max(seconds, retryInterval) }
        if let header = response?.value(forHTTPHeaderField: "Retry-After"),
           let advised = Double(header.trimmingCharacters(in: .whitespaces)) {
            seconds = min(15.0, max(seconds, advised))
        }
        seconds += Double.random(in: 0...0.4)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: File preallocation

    /// Size the destination file before segments seek into it, so each segment can
    /// write at its own offset without racing to grow the file.
    static func preallocate(_ url: URL, size: Int64) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    // MARK: Resume validators

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

    /// Guard a decoded resume cursor before trusting its ranges/offsets for file
    /// seeks: a corrupted or tampered on-disk cursor must trigger a fresh start,
    /// never an out-of-bounds seek (a negative offset traps `UInt64(_:)`). Verifies
    /// `completed` aligns with `ranges`, every range is ordered and within
    /// `[0, total)`, and each segment's completed-byte count fits its range.
    static func cursorIsWellFormed(_ cursor: ResumeCursor, total: Int64) -> Bool {
        guard cursor.completed.count == cursor.ranges.count else { return false }
        for (i, r) in cursor.ranges.enumerated() {
            guard r.start >= 0, r.end >= r.start, r.end < total else { return false }
            let done = cursor.completed[i]
            guard done >= 0, done <= r.end - r.start + 1 else { return false }
        }
        return true
    }

    // MARK: Resume cursor types

    struct Range64: Codable, Sendable {
        var start: Int64
        var end: Int64
    }

    /// Live, in-memory record of a segmented download's identity and layout, kept
    /// so the ledger can serialise a fresh ``ResumeCursor`` on each throttled tick.
    struct CursorMeta: Sendable {
        var etag: String?
        var lastModified: String?
        var total: Int64
        var ranges: [Range64]
    }

    /// The on-disk resume record: which byte ranges exist and how many bytes of
    /// each are complete, gated by `ETag` / `Last-Modified` validators.
    struct ResumeCursor: Codable, Sendable {
        var etag: String?
        var lastModified: String?
        var totalBytes: Int64
        var ranges: [Range64]
        var completed: [Int64]
    }

    // MARK: - Mirror pool

    /// Distributes segments across the primary + mirrors and tracks which of
    /// them have misbehaved. Demoted URLs are skipped; if everything ends up
    /// demoted the slate is wiped (the pool must never go empty — the primary
    /// deserves another chance before the whole download fails).
    actor MirrorPool {
        private let urls: [URL]
        private var demoted: Set<URL> = []

        init(primary: URL, mirrors: [URL]) {
            self.urls = [primary] + mirrors.filter { $0 != primary }
        }

        /// Round-robin by segment, shifting on each retry so a failed attempt
        /// lands on a different (healthy) URL.
        func url(segment: Int, attempt: Int) -> URL {
            let healthy = urls.filter { !demoted.contains($0) }
            let pool = healthy.isEmpty ? urls : healthy
            return pool[(segment + attempt - 1) % pool.count]
        }

        func demote(_ url: URL) {
            demoted.insert(url)
            if demoted.count >= urls.count { demoted.removeAll() }
        }
    }

    // MARK: - Ledger

    /// The single point of mutable transfer state. The byte pumps hop here once
    /// per flush to accumulate per-segment bytes, build the resume cursor and
    /// throttle progress — so the hot path stays off any shared executor and the
    /// counters are race-free.
    private actor Ledger {
        private let continuation: AsyncStream<TransferProgress>.Continuation
        private let meta: CursorMeta?
        private var segmentBytes: [Int: Int64]
        /// Constant for a download's lifetime (the live fan-out reported to the UI).
        private let connectionCount: Int
        /// Two-point speed window: the time and byte count at the previous emit.
        private var lastEmit = Date.distantPast
        private var lastEmitBytes: Int64 = 0
        private var lastResumeEmit = Date.distantPast
        /// Per-segment two-point speed window for the ~1 Hz connections snapshot.
        private var lastConnectionsEmit = Date.distantPast
        private var lastConnectionsBytes: [Int: Int64] = [:]

        init(continuation: AsyncStream<TransferProgress>.Continuation, meta: CursorMeta?,
             initialSegmentBytes: [Int: Int64], connectionCount: Int) {
            self.continuation = continuation
            self.meta = meta
            self.segmentBytes = initialSegmentBytes
            self.connectionCount = connectionCount
        }

        func totalBytes() -> Int64 { segmentBytes.values.reduce(0, +) }

        /// Record `n` flushed bytes for `segment` and, when the throttle allows,
        /// yield a progress tick (with a fresh resume cursor at most once a second).
        func advance(segment: Int, by n: Int) {
            segmentBytes[segment, default: 0] += Int64(n)
            let total = segmentBytes.values.reduce(0, +)

            let now = Date()
            guard now.timeIntervalSince(lastEmit) > 0.1 else { return }
            // O(1) two-point sliding window: speed since the previous emit.
            let dt = now.timeIntervalSince(lastEmit)
            let speed = (dt > 0 && dt < 3600) ? Double(total - lastEmitBytes) / dt : 0
            lastEmit = now
            lastEmitBytes = total

            continuation.yield(TransferProgress(
                bytesDownloaded: total, downloadSpeed: speed,
                connectionCount: connectionCount, resumeData: maybeResume(now: now),
                connections: maybeConnections(now: now, overallSpeed: speed)))
        }

        /// A per-segment snapshot for the detail panel's Connections/Progress
        /// tabs, throttled to ~1 Hz. Single-stream transfers (no range plan)
        /// report one connection row.
        private func maybeConnections(now: Date, overallSpeed: Double) -> [TaskConnection]? {
            let dt = now.timeIntervalSince(lastConnectionsEmit)
            guard dt >= 1.0 else { return nil }
            defer {
                lastConnectionsEmit = now
                lastConnectionsBytes = segmentBytes
            }
            guard let meta else {
                return [TaskConnection(
                    id: "seg-0", label: "Connection 1", detail: "single stream",
                    downloadSpeed: overallSpeed, progress: 0)]
            }
            return meta.ranges.indices.map { i in
                let range = meta.ranges[i]
                let length = range.end - range.start + 1
                let done = segmentBytes[i] ?? 0
                let speed = dt < 3600 ? Double(done - (lastConnectionsBytes[i] ?? 0)) / dt : 0
                return TaskConnection(
                    id: "seg-\(i)",
                    label: "Segment \(i + 1)",
                    detail: "\(Self.byteLabel(range.start)) – \(Self.byteLabel(range.end + 1))",
                    downloadSpeed: max(0, speed),
                    progress: length > 0 ? min(1, Double(done) / Double(length)) : 0)
            }
        }

        private static func byteLabel(_ n: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
        }

        /// A fresh resume cursor, throttled to once a second (nil for single-stream
        /// downloads, which cannot be resumed).
        private func maybeResume(now: Date) -> Data? {
            guard let meta else { return nil }
            if now.timeIntervalSince(lastResumeEmit) < 1.0 { return nil }
            lastResumeEmit = now
            return Self.buildResumeData(meta: meta, segmentBytes: segmentBytes)
        }

        /// The final resume cursor, ignoring the throttle (used to populate the
        /// transfer outcome).
        func currentResumeData() -> Data? {
            guard let meta else { return nil }
            return Self.buildResumeData(meta: meta, segmentBytes: segmentBytes)
        }

        private static func buildResumeData(meta: CursorMeta, segmentBytes: [Int: Int64]) -> Data? {
            let completed = meta.ranges.indices.map { segmentBytes[$0] ?? 0 }
            let cursor = ResumeCursor(
                etag: meta.etag, lastModified: meta.lastModified,
                totalBytes: meta.total, ranges: meta.ranges, completed: completed)
            return try? JSONEncoder().encode(cursor)
        }
    }
}

// MARK: - Supporting value types

/// Immutable description of one download's transfer mechanics, resolved by the
/// caller (``HTTPEngine``) from the probe result and the global connection budget.
struct TransferPlan: Sendable {
    var url: URL
    var destination: URL
    var totalBytes: Int64?
    var acceptsRanges: Bool
    var etag: String?
    var lastModified: String?
    var existingResume: Data?
    /// Resolved by the caller from the cross-download connection budget.
    var segmentCount: Int
    var session: URLSession
    var settings: RequestSettings
    var maxBytesPerSecond: Int64
    var flushSize: Int
    /// Alternative URLs for the same bytes. Only the segmented path uses them
    /// (a 206's Content-Range total proves a mirror serves the same file; the
    /// single-stream path has no such check, so it stays on the primary).
    var mirrors: [URL] = []
}

/// Per-request knobs threaded into the byte pumps (which read no actor state).
struct RequestSettings: Sendable {
    var userAgent: String
    var maxAttempts: Int
    var retryInterval: Double
    /// Preemptive `Authorization` header for protected hosts (nil = none).
    var authorization: String?
    /// Per-task `Referer` header (nil = none). Same-origin only — stripped on a
    /// cross-host mirror request, like ``authorization``.
    var referer: String?
    /// Extra per-task request headers (already sanitised of reserved names).
    /// Same-origin only — stripped on a cross-host mirror request.
    var extraHeaders: [String: String] = [:]
}

/// The result of a finished transfer.
struct TransferOutcome: Sendable {
    var bytesWritten: Int64
    var resumeData: Data?
    var usedSegments: Int
}

/// A throttled progress tick streamed out of a running transfer.
struct TransferProgress: Sendable {
    var bytesDownloaded: Int64
    var downloadSpeed: Double
    var connectionCount: Int
    /// A fresh resume cursor, present only on the (1 Hz) ticks that build one.
    var resumeData: Data?
    /// Per-segment snapshots, present only on the (~1 Hz) ticks that build them.
    var connections: [TaskConnection]?
}

// MARK: - Delegate-based chunked body reader

/// Bridges a `URLSessionDataTask`'s delegate callbacks into an
/// `AsyncThrowingStream<Data>` of body chunks — replacing `URLSession.bytes`,
/// whose one-`UInt8`-per-`await` iteration is CPU-bound and caps throughput on
/// fast links. Chunks arrive as `Data` (append = memcpy), so the byte pump is
/// network/disk-bound, not executor-bound.
///
/// **Flow control.** Bytes handed to the delegate but not yet pulled by the
/// consumer are counted; past a high-water mark the task is `suspend()`ed and
/// resumed once the consumer drains below the low-water mark. So a rate-limited
/// or disk-bound consumer exerts real TCP backpressure instead of buffering the
/// whole file in memory (`AsyncBytes` got this for free by pulling per byte).
///
/// **Redirects.** A per-task delegate supersedes the session delegate for its
/// task, so this replicates ``RedirectSanitizer``'s cross-host `Authorization`
/// stripping — otherwise a redirect could carry Basic credentials off-host.
///
/// Thread-safety: delegate callbacks arrive on the session's serial delegate
/// queue while the consumer runs on the transfer's task; the shared counters and
/// continuations are guarded by `lock`, so this is a sound `@unchecked Sendable`.
final class ChunkStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseCont: CheckedContinuation<HTTPURLResponse, Error>?
    private var bodyCont: AsyncThrowingStream<Data, Error>.Continuation?
    private weak var task: URLSessionTask?
    private var outstanding = 0
    private var suspended = false
    private var done = false

    private let highWater: Int
    private let lowWater: Int

    init(highWater: Int = 8 * 1024 * 1024, lowWater: Int = 2 * 1024 * 1024) {
        self.highWater = highWater
        self.lowWater = lowWater
    }

    /// Wire up the body continuation and task before the task is resumed.
    func prepare(body: AsyncThrowingStream<Data, Error>.Continuation, task: URLSessionTask) {
        lock.lock(); bodyCont = body; self.task = task; lock.unlock()
    }

    /// Register the response continuation; after this the task may be resumed.
    func setResponseContinuation(_ cont: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.lock(); responseCont = cont; lock.unlock()
    }

    /// The consumer calls this as it pulls each chunk off the stream, releasing
    /// backpressure credit — which may resume a suspended task.
    func consumed(_ n: Int) {
        lock.lock()
        outstanding -= n
        let resume = suspended && !done && outstanding <= lowWater
        if resume { suspended = false }
        let t = task
        lock.unlock()
        if resume { t?.resume() }
    }

    /// Abort the underlying transfer (reject/pause/remove). Safe to call after
    /// completion (a no-op on a finished task).
    func cancelTask() {
        lock.lock(); let t = task; lock.unlock()
        t?.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let cont = responseCont; responseCont = nil; lock.unlock()
        if let http = response as? HTTPURLResponse {
            cont?.resume(returning: http)
        } else {
            cont?.resume(throwing: DownloadError.network("No HTTP response"))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        outstanding += data.count
        let suspend = !suspended && outstanding >= highWater
        if suspend { suspended = true }
        let cont = bodyCont
        lock.unlock()
        cont?.yield(data)
        if suspend { dataTask.suspend() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let rcont = responseCont; responseCont = nil
        let bcont = bodyCont; bodyCont = nil
        done = true
        lock.unlock()
        if let error {
            // A failure before any response resolves the response await; otherwise
            // it terminates the body stream (so the consumer's `for await` throws).
            rcont?.resume(throwing: error)
            bcont?.finish(throwing: error)
        } else {
            // Clean completion with no response would strand the awaiter; guard it.
            rcont?.resume(throwing: DownloadError.network("No HTTP response"))
            bcont?.finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var sanitized = request
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        let downgradedToHTTP = request.url?.scheme?.lowercased() != "https"
        if sanitized.value(forHTTPHeaderField: "Authorization") != nil,
           originalHost != newHost || downgradedToHTTP {
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(sanitized)
    }
}

/// A thread-safe holder for a segment's currently-active ``ChunkStreamer`` so a
/// task-cancellation handler can abort whichever request is in flight (each retry
/// attempt swaps in a fresh streamer).
final class StreamerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ChunkStreamer?
    func set(_ streamer: ChunkStreamer) { lock.lock(); current = streamer; lock.unlock() }
    func cancel() { lock.lock(); let s = current; lock.unlock(); s?.cancelTask() }
}
