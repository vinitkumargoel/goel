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

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, range) in ranges.enumerated() {
                let already = initialBytes[i] ?? 0
                let segStart = range.start + already
                if segStart > range.end { continue } // segment already complete
                group.addTask {
                    try await self.downloadSegment(session: session, governor: governor, limiter: limiter,
                                                   ledger: ledger, url: self.plan.url, index: i,
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
                                 ledger: Ledger, url: URL, index: Int,
                                 from start: Int64, to end: Int64, fileURL: URL) async throws {
        let settings = plan.settings
        let flushSize = plan.flushSize
        let handle = try FileHandle(forWritingTo: fileURL)
        // Bytes of THIS segment already flushed to disk in this run. On a retry
        // we resume from `start + written`, so progress is never double-counted
        // and already-stored bytes are not re-fetched.
        var written: Int64 = 0
        var attempt = 0
        do {
            while start + written <= end {
                attempt += 1
                let segStart = start + written

                // Wait for a connection slot. The governor adapts the ceiling to
                // what the server actually tolerates (see ``ConnectionGovernor``).
                // Each `acquire()` below is balanced by exactly one `release()` on
                // every exit path of this attempt.
                await governor.acquire()
                var req = Self.makeRequest(url, userAgent: settings.userAgent)
                req.setValue("bytes=\(segStart)-\(end)", forHTTPHeaderField: "Range")

                let bytes: URLSession.AsyncBytes
                let http: HTTPURLResponse
                do {
                    let (b, resp) = try await session.bytes(for: req)
                    guard let h = resp as? HTTPURLResponse else {
                        await governor.release(); throw DownloadError.network("No HTTP response")
                    }
                    bytes = b; http = h
                } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
                    await governor.release()
                    try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                    continue
                } catch {
                    await governor.release(); throw error
                }

                if Self.isRetryableStatus(http.statusCode) {
                    for try await _ in bytes {}                       // drain the error body
                    await governor.throttleDown()                    // server pushed back: shrink the ceiling
                    await governor.release()
                    if attempt >= settings.maxAttempts { throw DownloadError.httpStatus(http.statusCode) }
                    try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                    continue
                }
                // Segments accept ONLY 206. A server that advertised range support
                // but answers a real ranged GET with 200 (full body) would have
                // every segment seek to its own offset and write the WHOLE file
                // there, overwriting siblings and corrupting the result. Reject it
                // as a clean, visible failure instead.
                guard http.statusCode == 206 else {
                    await governor.release(); throw DownloadError.httpStatus(http.statusCode)
                }

                do {
                    try handle.seek(toOffset: UInt64(segStart))
                    var buffer = Data()
                    buffer.reserveCapacity(flushSize)
                    // Cooperative cancellation flows from the AsyncBytes iterator,
                    // so we check once per flush rather than once per byte (the
                    // latter burns ~16% of a core at speed for no added safety).
                    for try await byte in bytes {
                        buffer.append(byte)
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
                    // last flushed offset.
                    await governor.release()
                    try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                    continue
                } catch {
                    await governor.release(); throw error
                }

                await governor.release()
                break                                                // segment complete
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
        // Retry only the connect/status phase: the no-range fallback can't
        // resume a partial body, so a mid-stream drop fails (rather than
        // silently restarting and double-counting progress).
        var attempt = 0
        let bytes: URLSession.AsyncBytes
        while true {
            attempt += 1
            let req = Self.makeRequest(url, userAgent: settings.userAgent)
            do {
                let (stream, resp) = try await session.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else { throw DownloadError.network("No HTTP response") }
                if Self.isRetryableStatus(http.statusCode), attempt < settings.maxAttempts {
                    for try await _ in stream {}                     // drain the error body
                    try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else { throw DownloadError.httpStatus(http.statusCode) }
                bytes = stream
                break
            } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
                try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                continue
            }
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            var buffer = Data()
            buffer.reserveCapacity(flushSize)
            for try await byte in bytes {
                buffer.append(byte)
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
            try? handle.close()
            throw error
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

    /// Builds a request carrying the client `User-Agent`. All outbound requests
    /// must go through here so none are sent UA-less (a missing UA causes some
    /// CDNs / WAFs to reset the connection, surfacing as -1005).
    static func makeRequest(_ url: URL, userAgent: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
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
                connectionCount: connectionCount, resumeData: maybeResume(now: now)))
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
}

/// Per-request knobs threaded into the byte pumps (which read no actor state).
struct RequestSettings: Sendable {
    var userAgent: String
    var maxAttempts: Int
    var retryInterval: Double
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
}
