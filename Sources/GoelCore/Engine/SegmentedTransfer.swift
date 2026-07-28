import Foundation
import CurlBridge

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
/// It owns NO cross-download state: the global / per-host ``ConnectionBudget`` and
/// task bookkeeping stay on ``HTTPEngine``, which resolves ``TransferPlan/segmentCount``
/// from that budget before wrapping a ``PlannedTransfer`` here. The byte pumps run
/// off any actor (this is a plain `Sendable` class, not an actor) and hop to an
/// internal ledger actor only once per flush — to accumulate per-segment bytes,
/// build the resume cursor and throttle progress — keeping the hot path off the
/// executor.
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

        // Resolve segmented-vs-single and the segment layout up front — cursor
        // decode + validation + range math, plus one `stat` of the destination to
        // confirm a cursor's bytes are still on disk — so the caller can reserve
        // the matching `connectionCount` before `run()`; the mutating file I/O
        // (preallocate) stays in `run()`.
        // A negative `totalBytes` is a broken (or hostile) `Content-Length` /
        // `Content-Range`; treat it as "size unknown" and drop to a single stream
        // rather than feed it to the range math and `preallocate`.
        guard let total = plan.totalBytes, total >= 0, plan.acceptsRanges else {
            self.segmented = false
            self.plannedRanges = []
            self.restoredBytes = [:]
            return
        }
        let multiPath = plan.boundAdapters.count >= 2
        let wanted = multiPath
            ? max(plan.segmentCount, plan.boundAdapters.count)
            : plan.segmentCount

        if let data = plan.existingResume,
           let cursor = try? JSONDecoder().decode(ResumeCursor.self, from: data),
           cursor.totalBytes == total,
           Self.cursorIsWellFormed(cursor, total: total),
           Self.validatorsAllowResume(
                cursorETag: cursor.etag, cursorLastModified: cursor.lastModified,
                probeETag: plan.etag, probeLastModified: plan.lastModified),
           // Multi-path needs ≥1 range per adapter. A stale single-segment resume
           // from before aggregation was enabled would pin everything to one NIC.
           // The mid-flight upgrade legitimately produces single-range cursors too
           // (a W == 0 trip with a zero grant); rejecting those here is harmless —
           // nothing was on disk — not a bug.
           !(multiPath && cursor.ranges.count < plan.boundAdapters.count
             && cursor.completed.allSatisfy { $0 == 0 }),
           // …and the bytes the cursor claims are on disk must actually still be
           // there (see ``destinationHoldsPreallocation``). Checked last: it is the
           // only condition that touches the filesystem.
           Self.destinationHoldsPreallocation(plan.destination, total: total) {
            // Remote unchanged and cursor sound: continue from where we left off.
            self.segmented = true
            self.plannedRanges = cursor.ranges
            self.restoredBytes = Dictionary(
                uniqueKeysWithValues: cursor.completed.enumerated().map { ($0.offset, $0.element) })
        } else {
            // Fresh start (or remote changed / cursor unusable / multi-path upgrade).
            self.segmented = true
            let count = multiPath
                ? Self.clampSegmentCount(wanted, total: total, minSegment: 32 * 1024)
                : Self.clampSegmentCount(wanted, total: total)
            self.plannedRanges = Self.makeRanges(total: total, count: count)
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
        // `segmented` is only ever set alongside a present, non-negative
        // `totalBytes`; binding it here states that in the type system instead of
        // force-unwrapping a value parsed out of a server header.
        guard segmented, let total = plan.totalBytes else {
            // Pinned to an interface but unable to split: URLSession cannot bind, so
            // the whole body goes through the curl path instead of silently
            // ignoring the pin and egressing the default route.
            if let adapter = plan.boundAdapters.first {
                return try await runSingleBound(adapter)
            }
            return try await runSingle()
        }
        return try await runSegmented(total: total, ranges: plannedRanges,
                                      restored: restoredBytes, upgraded: false)
    }

    // MARK: Pacing

    /// The pacer this transfer's flushes go through: the task's own cap (when it
    /// has one) chained in front of the engine-wide pacer, so the profile ceiling
    /// holds in SUM across concurrent downloads while a per-task limit stays
    /// private to this transfer. Either may be absent; `nil` means unlimited.
    /// `static` (and `internal`) so the selection is assertable without moving bytes.
    static func makeLimiter(_ plan: TransferPlan) -> RateLimiter? {
        guard plan.maxBytesPerSecond > 0 else { return plan.sharedLimiter }
        return RateLimiter(bytesPerSecond: plan.maxBytesPerSecond, next: plan.sharedLimiter)
    }

    // MARK: Segmented download

    /// `ranges`/`restored` are the init-resolved layout for the normal callers;
    /// the mid-flight upgrade passes a synthesized layout instead (completed
    /// prefix + freshly-cut tail) with `upgraded: true`, which arms the
    /// ranged-200 flap-back retry in the segment pumps.
    private func runSegmented(total: Int64, ranges: [Range64],
                              restored: [Int: Int64], upgraded: Bool) async throws -> TransferOutcome {
        try Self.preallocate(plan.destination, size: total)

        let initialBytes = Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, restored[$0] ?? 0) })
        let meta = CursorMeta(etag: plan.etag, lastModified: plan.lastModified, total: total, ranges: ranges)
        let ledger = Ledger(continuation: continuation, meta: meta,
                            initialSegmentBytes: initialBytes, connectionCount: ranges.count,
                            expectedTotal: total)

        let limiter = Self.makeLimiter(plan)
        let session = plan.session
        // One governor per download: it begins at the requested fan-out and
        // adapts down to the server's real concurrent-connection ceiling.
        let governor = ConnectionGovernor(limit: ranges.count)
        // Segments spread across the primary + mirrors round-robin; a mirror
        // that misbehaves is demoted and its segment retries elsewhere.
        // An UPGRADED transfer stays on the primary. Mirrors are admitted on the
        // strength of a Content-Range total alone, which is fine when every byte
        // comes from the pool — but here bytes [0, W-1] are already on disk from
        // the primary stream, and both edges of the validator triangle were checked
        // against the primary only. Letting the tail come from a same-sized but
        // differently-contented mirror (in-place rsync, staggered release) would
        // splice two entities into one file and still report `.completed`. This
        // also preserves what `TransferPlan.mirrors` documents: a download that
        // started single-stream stays on the primary.
        let pool = MirrorPool(primary: plan.url, mirrors: upgraded ? [] : plan.mirrors)
        // Pin segments to bound adapters via CurlBridge bind-if. One adapter is a
        // valid plan — a task pinned to a single NIC still has to egress it.
        let adapterPool: AdapterPool? = plan.boundAdapters.isEmpty
            ? nil : AdapterPool(plan.boundAdapters)
        // One governor per adapter, each starting wide open (limit = ranges.count) so
        // behavior is byte-identical to today until the first 429 arrives on some path.
        let adapterGovernors: AdapterGovernors? = plan.boundAdapters.isEmpty
            ? nil : AdapterGovernors(adapters: plan.boundAdapters, limit: ranges.count)
        if let adapterPool {
            // Seed ledger adapter labels for Connections UI before first tick.
            for i in ranges.indices {
                if let a = await adapterPool.assign(segment: i) {
                    await ledger.setAdapter(segment: i, id: a.bsdName, label: a.label)
                }
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, range) in ranges.enumerated() {
                let already = initialBytes[i] ?? 0
                let segStart = range.start + already
                if segStart > range.end { continue } // segment already complete
                group.addTask {
                    if let adapterPool, let adapterGovernors {
                        try await self.downloadSegmentBound(
                            governor: governor, adapterGovernors: adapterGovernors,
                            limiter: limiter, ledger: ledger,
                            pool: pool, adapters: adapterPool, index: i,
                            from: segStart, to: range.end, fileURL: self.plan.destination,
                            upgraded: upgraded)
                    } else {
                        try await self.downloadSegment(session: session, governor: governor, limiter: limiter,
                                                       ledger: ledger, pool: pool, index: i,
                                                       from: segStart, to: range.end, fileURL: self.plan.destination,
                                                       upgraded: upgraded)
                    }
                }
            }
            try await group.waitForAll()
        }

        let bytesWritten = await ledger.totalBytes()
        // Aggregate completeness net: every segment individually verified its range
        // above, but assert the whole file is accounted for before reporting success
        // so a silent gap can never be emitted as `.completed`.
        guard bytesWritten == total else {
            throw DownloadError.network("Incomplete download: wrote \(bytesWritten) of \(total) bytes")
        }
        let resumeData = await ledger.currentResumeData()
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: resumeData, usedSegments: ranges.count)
    }

    /// The byte pump runs OFF any actor (this is a plain class) — otherwise every
    /// segment would serialize through an executor (one hop per byte), defeating
    /// the whole point of segmented downloading. It hops to the ledger actor (via
    /// `await ledger.advance`) only once per ~`flushSize` flush.
    private func downloadSegment(session: URLSession, governor: ConnectionGovernor, limiter: RateLimiter?,
                                 ledger: Ledger, pool: MirrorPool, index: Int,
                                 from start: Int64, to end: Int64, fileURL: URL,
                                 upgraded: Bool) async throws {
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
                    try await governor.acquire()
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

                    switch Self.classify(http.statusCode, ranged: true) {
                    case .retry:
                        streamer.cancelTask()                            // stop the error body
                        if isMirror { await pool.demote(url) }
                        await governor.throttleDown()                    // server pushed back: shrink the ceiling
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.httpStatus(http.statusCode) }
                        try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                        continue
                    case .reject:
                        if upgraded, http.statusCode == 200, attempt < settings.maxAttempts {
                            // Range support flapped back mid-upgrade (cold edge). The
                            // probe that triggered this phase just saw a 206, so a warm
                            // edge exists; retry with backoff instead of failing a
                            // download that was completing without us.
                            streamer.cancelTask()                        // never drain the full body
                            if isMirror { await pool.demote(url) }
                            await governor.release()
                            try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                            continue
                        }
                        // A ranged GET answered with a non-206 (e.g. a full 200 body)
                        // is unusable for a segment (see ``classify``). A mirror that
                        // can't do ranges is demoted and the segment retries elsewhere;
                        // the primary fails visibly.
                        streamer.cancelTask()
                        await governor.release()
                        if isMirror, attempt < settings.maxAttempts {
                            await pool.demote(url)
                            continue
                        }
                        throw DownloadError.httpStatus(http.statusCode)
                    case .accept:
                        break   // 206 — proceed to the mirror content-range check + body
                    }
                    // Every 206 (primary *and* mirror, any adapter path) must describe
                    // the same total size — geo-split / wrong-object must not merge.
                    if let expected = plan.totalBytes,
                       let got = Self.contentRangeTotal(http),
                       got != expected {
                        streamer.cancelTask()
                        if isMirror { await pool.demote(url) }
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.remoteFileChanged }
                        continue
                    }

                    do {
                        try handle.seek(toOffset: UInt64(segStart))
                        // `written` advances per flush so a mid-body retry resumes
                        // from the last flushed offset without double-counting.
                        try await pumpBody(bytes, into: handle, streamer: streamer, ledger: ledger,
                                           segment: index, limiter: limiter, flushSize: flushSize,
                                           written: &written)
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
                    // `pumpBody` returned without throwing, but a clean completion
                    // does NOT prove the whole range arrived: a close-delimited body
                    // (no Content-Length, not chunked) or a body ended by an early
                    // zero-length chunk surfaces to `ChunkStreamer` as a no-error
                    // `didCompleteWithError`, so the pump loop simply ends. Only
                    // finish the segment once the full requested range is on disk;
                    // otherwise the unfetched tail would be left as a silent gap of
                    // zero bytes in the preallocated file.
                    if start + written > end { break }                   // segment complete
                    if attempt >= settings.maxAttempts {
                        throw DownloadError.network(
                            "Incomplete segment \(index): got \(written) of \(end - start + 1) bytes")
                    }
                    // Clean but short: back off and retry the remaining range from
                    // the last flushed offset (segStart advances via `written`).
                    try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
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

    // MARK: Multi-path (interface-bound) segmented download

    /// Same segment pump as ``downloadSegment`` but each attempt uses
    /// ``BoundHTTPClient`` (CurlBridge + IP_BOUND_IF / SO_BINDTODEVICE) so
    /// traffic egresses a chosen adapter. Adapters are assigned round-robin and
    /// demoted on bind/auth failures; mirrors still provide URL failover.
    private func downloadSegmentBound(
        governor: ConnectionGovernor, adapterGovernors: AdapterGovernors,
        limiter: RateLimiter?,
        ledger: Ledger, pool: MirrorPool, adapters: AdapterPool,
        index: Int, from start: Int64, to end: Int64, fileURL: URL,
        upgraded: Bool
    ) async throws {
        let settings = plan.settings
        let handle = try FileHandle(forWritingTo: fileURL)
        var written: Int64 = 0
        var attempt = 0
        do {
            try await withTaskCancellationHandler {
                while start + written <= end {
                    try Task.checkCancellation()
                    attempt += 1
                    let segStart = start + written
                    let url = await pool.url(segment: index, attempt: attempt)
                    // Match URLSession path: strip secrets only on host change.
                    let isCrossHost = url.host?.lowercased() != plan.url.host?.lowercased()
                    let isMirror = url != plan.url
                    guard let adapter = await adapters.assign(segment: index + attempt - 1) else {
                        throw DownloadError.network("No network adapters available for multi-path")
                    }
                    await ledger.setAdapter(segment: index, id: adapter.bsdName, label: adapter.label)

                    try await governor.acquire()
                    // Global THEN adapter, always in that order; a cancellation
                    // parked on the adapter governor must hand the already-claimed
                    // global slot back before rethrowing, or the slot leaks.
                    do { try await adapterGovernors.acquire(adapter.bsdName) }
                    catch { await governor.release(); throw error }
                    var reqSettings = settings
                    if isCrossHost {
                        reqSettings.authorization = nil
                        reqSettings.referer = nil
                        reqSettings.extraHeaders = [:]
                    }
                    let boundReq = BoundHTTPClient.Request(
                        url: url,
                        rangeStart: segStart,
                        rangeEnd: end,
                        interfaceName: adapter.bsdName,
                        userAgent: reqSettings.userAgent,
                        referer: reqSettings.referer,
                        authorization: reqSettings.authorization,
                        extraHeaders: reqSettings.extraHeaders,
                        connectTimeout: plan.connectTimeout,
                        expectedTotal: plan.totalBytes
                    )

                    // curl's write callback cannot await; it tallies and this pump
                    // folds the bytes into the ledger every 200 ms so progress ticks
                    // — and the 1 Hz resume cursor — reflect what is already on disk
                    // mid-attempt. onBytes fires only after the write succeeded, and
                    // C drains every non-accepted body without reaching the write
                    // callback, so the tally is exactly the bytes on disk.
                    let tally = ByteTally()
                    let pump = Task { [tally] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            let n = tally.drain()
                            if n > 0 { await ledger.advance(segment: index, by: n) }
                        }
                    }
                    let response = await BoundHTTPClient.downloadRange(
                        boundReq, file: handle, fileOffset: UInt64(segStart),
                        limiter: limiter,
                        onBytes: { [tally] in tally.add($0) })
                    pump.cancel()
                    _ = await pump.value
                    // Drain before ANY branching so retry offsets are computed from
                    // a ledger fully credited for this attempt.
                    let trailing = tally.drain()
                    if trailing > 0 { await ledger.advance(segment: index, by: trailing) }

                    if response.aborted && !response.rangeTotalMismatch {
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        throw CancellationError()
                    }

                    // Content-Range mismatch: CurlBridge aborts before writing body.
                    // Do not credit ledger or `written`.
                    if response.rangeTotalMismatch {
                        if isMirror { await pool.demote(url) }
                        await adapters.demote(adapter)
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.remoteFileChanged }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    }

                    // Must precede the curl-error branch: the C early abort for a
                    // ranged 200 surfaces as CURLE_WRITE_ERROR.
                    if response.rangeIgnored {
                        // Server ignored Range (flap-back). C aborted on the first body
                        // byte, so nothing was written or tallied. Retryable in the
                        // upgraded phase (and for mirrors, as the old classify-reject
                        // already allowed); terminal 200 on the primary otherwise —
                        // identical to today's error, minus the full-body drain the
                        // old path paid.
                        if isMirror { await pool.demote(url) }
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        if (upgraded || isMirror), attempt < settings.maxAttempts {
                            try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                            continue
                        }
                        throw DownloadError.httpStatus(200)
                    }

                    // Curl transport errors. The tally pump already credited the
                    // ledger (Σ onBytes == bytesWritten); only the retry-resume
                    // offset is committed here, so no byte is counted twice.
                    if response.curlCode != 0 {
                        if response.bytesWritten > 0 {
                            written += response.bytesWritten
                        }
                        await adapters.demote(adapter)
                        if isMirror { await pool.demote(url) }
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        if attempt >= settings.maxAttempts {
                            throw DownloadError.network(
                                Self.transportError(response.curlCode, via: adapter))
                        }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    }

                    let status = response.httpStatus
                    switch Self.classify(status, ranged: true) {
                    case .retry:
                        if isMirror { await pool.demote(url) }
                        // Per-IP pushback belongs to the path that received it: only
                        // this adapter's ceiling shrinks; the download-wide governor
                        // keeps the aggregate at ranges.count so healthy NICs are
                        // never starved by one throttled source address.
                        await adapterGovernors.throttleDown(adapter.bsdName)
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.httpStatus(status) }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    case .reject:
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        if status == 401 || status == 403 {
                            await adapters.demote(adapter)
                        }
                        // Ranged-200 flap-back with an EMPTY body. The `rangeIgnored`
                        // branch above catches the usual shape, but C only sets that
                        // flag from the write thunk — a 200 carrying zero bytes never
                        // invokes it and lands here instead. Same situation, same
                        // answer as the URLSession pump: the probe that armed this
                        // phase just saw a 206, so a warm edge exists and failing the
                        // whole upgraded download would be wrong.
                        if upgraded, status == 200, attempt < settings.maxAttempts {
                            if isMirror { await pool.demote(url) }
                            try await backoff(attempt: attempt, response: nil,
                                              retryInterval: settings.retryInterval)
                            continue
                        }
                        if isMirror, attempt < settings.maxAttempts {
                            await pool.demote(url)
                            continue
                        }
                        throw DownloadError.httpStatus(status)
                    case .accept:
                        break
                    }

                    // Multi-path requires a matching Content-Range total (Swift-side belt).
                    if let expected = plan.totalBytes {
                        guard let got = response.contentRangeTotal, got == expected else {
                            if isMirror { await pool.demote(url) }
                            await adapters.demote(adapter)
                            await adapterGovernors.release(adapter.bsdName)
                            await governor.release()
                            if attempt >= settings.maxAttempts { throw DownloadError.remoteFileChanged }
                            try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                            continue
                        }
                    }

                    // The ledger already holds these bytes via the tally pump; only
                    // the offset bookkeeping the completeness check reads is
                    // committed here.
                    if response.bytesWritten > 0 {
                        written += response.bytesWritten
                    }
                    await adapterGovernors.release(adapter.bsdName)
                    await governor.release()

                    if start + written > end { break }
                    if response.bytesWritten == 0 {
                        await adapters.demote(adapter)
                        if attempt >= settings.maxAttempts {
                            throw DownloadError.network(
                                "Incomplete segment \(index): got \(written) of \(end - start + 1) bytes")
                        }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    }
                    if start + written <= end {
                        if attempt >= settings.maxAttempts {
                            throw DownloadError.network(
                                "Incomplete segment \(index): got \(written) of \(end - start + 1) bytes")
                        }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                    }
                }
            } onCancel: {
                // BoundHTTPClient observes Task cancellation via withTaskCancellationHandler.
            }
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
                            initialSegmentBytes: [0: 0], connectionCount: 1,
                            expectedTotal: plan.totalBytes)
        let limiter = Self.makeLimiter(plan)

        let upgrade = spawnUpgradeProber()
        defer { upgrade?.task.cancel() }              // covers completion, failure, cancellation
        do {
            try await streamSingle(session: plan.session, limiter: limiter, ledger: ledger,
                                   url: plan.url, fileURL: plan.destination,
                                   upgrade: upgrade?.signal)
        } catch let interrupt as UpgradeInterrupt {
            guard let upgrade else { throw interrupt } // unreachable: interrupt implies a prober
            let written = await ledger.totalBytes()    // == flushed == on-disk bytes
            return try await upgradeToSegmented(total: upgrade.total, written: written)
        }

        let bytesWritten = await ledger.totalBytes()
        // When the server declared a size (Content-Length known but ranges not
        // supported), verify the whole body actually arrived — a close-delimited
        // stream can end cleanly while short, and reporting that as `.completed`
        // would be silent truncation. A genuinely size-unknown stream (totalBytes
        // == nil) has nothing to check against.
        if let total = plan.totalBytes, bytesWritten != total {
            throw DownloadError.network("Incomplete download: wrote \(bytesWritten) of \(total) bytes")
        }
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: nil, usedSegments: 1)
    }

    /// Single-connection download pinned to one interface.
    ///
    /// Used when the task names an interface but the transfer cannot be segmented
    /// (no size, or no range support). Unlike ``runSingle`` this goes through
    /// CurlBridge, because `URLSession` has no equivalent of `SO_BINDTODEVICE`.
    /// The body cannot resume, so — like ``runSingle`` — only the connect/status
    /// phase retries; once bytes are on disk a failure is terminal.
    private func runSingleBound(_ adapter: BoundAdapter) async throws -> TransferOutcome {
        try Data().write(to: plan.destination)

        let ledger = Ledger(continuation: continuation, meta: nil,
                            initialSegmentBytes: [0: 0], connectionCount: 1,
                            expectedTotal: plan.totalBytes)
        await ledger.setAdapter(segment: 0, id: adapter.bsdName, label: adapter.label)

        let limiter = Self.makeLimiter(plan)
        let settings = plan.settings
        let handle = try FileHandle(forWritingTo: plan.destination)
        let tally = ByteTally()
        var attempt = 0

        let upgrade = spawnUpgradeProber()
        defer { upgrade?.task.cancel() }              // covers completion, failure, cancellation
        // The trip is read by all three of BoundHTTPClient's abort consumers, so
        // whichever runs first stops curl: mid-body that is the write thunk
        // (CURLE_WRITE_ERROR), pre-body the progress thunk. Either way
        // `Response.aborted` re-reads the closure, so the branch below is taken
        // regardless of which channel fired — that, not a single guaranteed curl
        // code, is what makes the trip unmissable.
        let shouldAbort: (@Sendable () -> Bool)?
        if let upgrade {
            let signal = upgrade.signal
            shouldAbort = { signal.isTripped }
        } else {
            shouldAbort = nil
        }

        while true {
            try Task.checkCancellation()
            attempt += 1
            let request = BoundHTTPClient.Request(
                url: plan.url,
                rangeStart: -1,             // no Range header — stream the whole body
                rangeEnd: -1,
                interfaceName: adapter.bsdName,
                userAgent: settings.userAgent,
                referer: settings.referer,
                authorization: settings.authorization,
                extraHeaders: settings.extraHeaders,
                connectTimeout: plan.connectTimeout,
                expectedTotal: nil          // no Content-Range to check against
            )

            // curl's write callback cannot await, so it tallies bytes and this pump
            // folds them into the ledger — otherwise progress would jump 0 → done.
            let pump = Task { [tally] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    let n = tally.drain()
                    if n > 0 { await ledger.advance(segment: 0, by: n) }
                }
            }
            let response = await BoundHTTPClient.downloadRange(
                request, file: handle, fileOffset: 0, limiter: limiter,
                onBytes: { [tally] in tally.add($0) },
                shouldAbort: shouldAbort)
            pump.cancel()
            _ = await pump.value
            let trailing = tally.drain()
            if trailing > 0 { await ledger.advance(segment: 0, by: trailing) }

            if response.aborted {
                // Signal-abort is an upgrade; task-cancellation abort stays a
                // pause/remove. If both raced, cancellation wins — the engine's
                // pause owns the transition.
                if let upgrade, upgrade.signal.isTripped, !Task.isCancelled {
                    try handle.close()                       // flush failure = real failure
                    let written = await ledger.totalBytes()
                    switch Self.classify(response.httpStatus, ranged: false) {
                    case .accept:
                        // Stream edge of the validator triangle: ranged tail bytes may
                        // only be mixed under a prefix provably from the same entity.
                        // The two edges see different representations though — the
                        // probe rides URLSession (Accept-Encoding: gzip…) while this
                        // stream rides curl (identity, see gcb_http_headers), and
                        // Apache/nginx suffix or weaken the ETag per encoding — so a
                        // mismatch here routinely means "same file, different
                        // representation", NOT a changed remote. Failing the download
                        // on it would break transfers that complete fine without the
                        // upgrade, and it would not self-heal: the retry re-probes to
                        // the same unranged verdict and trips again.
                        // Dropping the unprovable prefix and re-fetching over ranges
                        // is both correct (every byte then comes from the ranged
                        // entity) and still faster than the single stream it replaces.
                        // written == total is settled first: the trip landed on the
                        // final flush, so there is nothing to segment and
                        // `upgradeToSegmented` short-circuits to the finished outcome.
                        let keepsPrefix = written == 0 || written == upgrade.total
                            || Self.validatorsAllowResume(
                                cursorETag: plan.etag, cursorLastModified: plan.lastModified,
                                probeETag: response.etag, probeLastModified: response.lastModified)
                        if !keepsPrefix {
                            GoelLog.engineHTTP.notice(
                                "Mid-flight upgrade: streamed prefix not provably the probed entity; refetching over ranges",
                                .bytes(written, label: "discarded"),
                                .url(plan.url))
                        }
                        return try await upgradeToSegmented(
                            total: upgrade.total, written: keepsPrefix ? written : 0)
                    case .retry:
                        // The unranged GET is being 429/5xx'd while ranges just
                        // probed 206: upgrading IS the retry. written == 0 (error
                        // bodies drain in C).
                        return try await upgradeToSegmented(total: upgrade.total, written: written)
                    case .reject:
                        if response.httpStatus == 0 {
                            // Tripped during connect, before any response arrived:
                            // nothing on disk (written == 0), no status to honour.
                            return try await upgradeToSegmented(total: upgrade.total, written: written)
                        }
                        // A terminal status (401/403/404…) surfaces as itself instead
                        // of being laundered through an upgrade whose segments would
                        // re-fail against the same host after a pointless
                        // grant/release cycle.
                        throw DownloadError.httpStatus(response.httpStatus)
                    }
                }
                try? handle.close()
                throw CancellationError()
            }
            // Anything already written rules out a retry: restarting an unranged
            // stream would append a second copy of the body.
            let canRetry = response.bytesWritten == 0 && attempt < settings.maxAttempts

            if response.curlCode != 0 {
                if canRetry {
                    try await backoff(attempt: attempt, response: nil,
                                      retryInterval: settings.retryInterval)
                    continue
                }
                try? handle.close()
                throw DownloadError.network(
                    Self.transportError(response.curlCode, via: adapter))
            }

            let decision = Self.classify(response.httpStatus, ranged: false)
            if decision == .retry, canRetry {
                try await backoff(attempt: attempt, response: nil,
                                  retryInterval: settings.retryInterval)
                continue
            }
            guard decision == .accept else {
                try? handle.close()
                throw DownloadError.httpStatus(response.httpStatus)
            }
            break
        }

        try handle.close()
        let bytesWritten = await ledger.totalBytes()
        if let total = plan.totalBytes, bytesWritten != total {
            throw DownloadError.network("Incomplete download: wrote \(bytesWritten) of \(total) bytes")
        }
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: nil, usedSegments: 1)
    }

    /// Single-connection body pump (see ``downloadSegment`` for why it runs off
    /// the actor).
    private func streamSingle(session: URLSession, limiter: RateLimiter?, ledger: Ledger,
                              url: URL, fileURL: URL, upgrade: UpgradeSignal?) async throws {
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
                // A stream stuck in connect/status retries (server 503s the
                // unranged GET while happily 206ing ranges) must still honour a
                // trip — nothing has streamed yet, so W == 0 and there is no
                // entity edge to verify.
                if let upgrade, upgrade.isTripped { throw UpgradeInterrupt() }
                attempt += 1
                let req = Self.makeRequest(url, settings: settings)
                do {
                    let opened = try await Self.openStream(
                        session: session, request: req) { streamerBox.set($0) }
                    let decision = Self.classify(opened.0.statusCode, ranged: false)
                    if decision == .retry, attempt < settings.maxAttempts {
                        opened.2.cancelTask()                        // drop the error body
                        try await backoff(attempt: attempt, response: opened.0, retryInterval: settings.retryInterval)
                        continue
                    }
                    guard decision == .accept else {
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
            guard let (http, bytes, streamer) = result else { return }

            // The 200 actually streaming must be the entity the probe described:
            // the on-disk prefix and any ranged tail fetched after an upgrade must
            // come from one representation. On mismatch the stream is left to
            // complete untouched (today's behavior); only the upgrade is disabled.
            let pumpUpgrade: UpgradeSignal?
            if let upgrade {
                let entityTied = Self.validatorsAllowResume(
                    cursorETag: plan.etag, cursorLastModified: plan.lastModified,
                    probeETag: http.value(forHTTPHeaderField: "ETag"),
                    probeLastModified: http.value(forHTTPHeaderField: "Last-Modified"))
                if !entityTied {
                    GoelLog.engineHTTP.debug("Mid-flight upgrade disabled: stream entity differs from probe",
                                             .url(plan.url))
                }
                pumpUpgrade = entityTied ? upgrade : nil
            } else {
                pumpUpgrade = nil
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            do {
                // A single stream can't resume a partial body, so the flushed count
                // is unused here — but the flush/throttle loop is the shared pump.
                var written: Int64 = 0
                try await pumpBody(bytes, into: handle, streamer: streamer, ledger: ledger,
                                   segment: 0, limiter: limiter, flushSize: flushSize, written: &written,
                                   upgrade: pumpUpgrade)
                try handle.close()
            } catch let interrupt as UpgradeInterrupt {
                // The upgrade route is the one error path whose on-disk bytes are
                // KEPT: `ledger.totalBytes()` becomes a completed prefix segment that
                // `runSegmented` skips and never re-fetches. A close(2) failure here
                // (NFS/SMB surfacing a late write error) would leave a hole inside
                // [0, W-1] that the tail segments never cover and the completeness
                // check — which only sums the ledger — cannot see. Same rule the
                // bound twin already applies: flush failure = real failure.
                streamer.cancelTask()
                try handle.close()
                throw interrupt
            } catch {
                streamer.cancelTask()
                try? handle.close()
                throw error
            }
        } onCancel: {
            streamerBox.cancel()
        }
    }

    /// Drain `bytes` into `handle`, flushing to disk every `flushSize` and folding
    /// each flush into `ledger` (under `segment`) and the rate `limiter`. Shared by
    /// both pumps so the flush/throttle loop lives once. `written` accumulates the
    /// bytes flushed in THIS call, updated incrementally so that if the stream
    /// throws mid-body the ledger has already counted the flushed prefix and a
    /// segment retry can resume from the right offset without double-counting.
    /// Cancellation is checked once per flush; the caller owns cancel/close on the
    /// error path (each pump handles a mid-body failure differently).
    private func pumpBody(_ bytes: AsyncThrowingStream<Data, Error>, into handle: FileHandle,
                          streamer: ChunkStreamer, ledger: Ledger, segment: Int,
                          limiter: RateLimiter?, flushSize: Int, written: inout Int64,
                          upgrade: UpgradeSignal? = nil) async throws {
        // Body arrives as `Data` chunks from the task delegate (not one byte per
        // `await`), so appends are memcpys and the loop isn't CPU-bound. `consumed`
        // releases backpressure credit as each chunk leaves the stream.
        var buffer = Data()
        buffer.reserveCapacity(flushSize)
        for try await chunk in bytes {
            buffer.append(chunk)
            streamer.consumed(chunk.count)
            if buffer.count >= flushSize {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                await ledger.advance(segment: segment, by: buffer.count)
                // Pace against the profile's aggregate download cap. The pacer
                // behind this one is shared across all segments AND across every
                // concurrent download, so combined throughput converges on the cap
                // (no-op when unlimited).
                await limiter?.pace(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Stop exactly at a flush boundary: `written` then equals the bytes
                // on disk, which becomes the upgrade's completed prefix.
                if let upgrade, upgrade.isTripped { throw UpgradeInterrupt() }
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            await ledger.advance(segment: segment, by: buffer.count)
            await limiter?.pace(buffer.count)
        }
    }

    // MARK: Range math

    /// The size-only clamp, factored out as `static` so ``init`` can resolve the
    /// fan-out before any instance method is available.
    static func clampSegmentCount(_ requested: Int, total: Int64,
                                  minSegment: Int64 = 64 * 1024) -> Int {
        // `(total - 1) / minSegment + 1` rather than `(total + minSegment - 1) / …`:
        // the latter overflows — and traps — on a declared size near `Int64.max`.
        let bySize = total <= 0 ? 1 : Int(min(Int64(Int.max), (total - 1) / minSegment + 1))
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

    // MARK: Mid-flight upgrade (single stream → segmented)

    /// Below this size a mid-flight re-segmentation costs more than it saves.
    static let upgradeMinBytes: Int64 = 8 * 1024 * 1024
    /// Mirrors ``AggregationPolicy/multiPathSegmentCount``'s hard cap; the engine
    /// clamps further by profile/budget when granting.
    static let upgradeMaxConnections = 32

    /// The pump's cooperative-stop sentinel; it is never a failure.
    private struct UpgradeInterrupt: Error {}

    /// Without a validator the streamed prefix cannot be proven identical to ranged
    /// bytes fetched later, so the upgrade must never fire.
    static func shouldAttemptUpgrade(totalBytes: Int64?, acceptsRanges: Bool,
                                     etag: String?, lastModified: String?) -> Bool {
        guard let total = totalBytes, total >= upgradeMinBytes, !acceptsRanges else { return false }
        return etag != nil || lastModified != nil
    }

    /// Layout for a single stream upgrading to segments: a completed prefix
    /// [0, written) restored as segment 0 (omitted when nothing was flushed), and
    /// the remainder cut with the same clamp math a fresh plan would use.
    static func upgradedLayout(total: Int64, written: Int64, connections: Int,
                               minSegment: Int64 = 64 * 1024) -> (ranges: [Range64], restored: [Int: Int64]) {
        let remainder = max(0, total - written)
        let count = clampSegmentCount(max(1, connections), total: remainder, minSegment: minSegment)
        let tail = makeRanges(total: remainder, count: count)
            .map { Range64(start: $0.start + written, end: $0.end + written) }
        guard written > 0 else { return (tail, [:]) }
        return ([Range64(start: 0, end: written - 1)] + tail, [0: written])
    }

    /// nil when the plan can never upgrade (gate fails, or the engine supplied no
    /// budget channel — so every plan built without the closure keeps today's
    /// behavior bit-for-bit). Caller owns cancellation: `defer { upgrade?.task.cancel() }`.
    private func spawnUpgradeProber() -> (task: Task<Void, Never>, signal: UpgradeSignal, total: Int64)? {
        guard plan.requestExtraConnections != nil,
              Self.shouldAttemptUpgrade(totalBytes: plan.totalBytes,
                                        acceptsRanges: plan.acceptsRanges,
                                        etag: plan.etag, lastModified: plan.lastModified),
              let total = plan.totalBytes else { return nil }
        let signal = UpgradeSignal()
        let probing = plan.upgradeProbing
        // Unstructured and capturing only value state (no `self` → no retain
        // cycle); a cancelled sleep returns immediately (the stream ended first).
        let task = Task { [plan] in
            for attempt in 0..<max(0, probing.maxAttempts) {
                let delay = attempt == 0 ? probing.initialDelay : probing.interval
                do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) }
                catch { return }
                if Task.isCancelled { return }
                if await Self.probeMidpointRange(plan: plan, total: total) {
                    signal.trip()
                    return
                }
            }
        }
        return (task, signal, total)
    }

    /// One ranged header probe at the file midpoint. MUST use the openStream +
    /// cancelTask pattern (see ``HTTPEngine/probe``): a server that ignores Range
    /// answers 200 with the WHOLE body, and any buffering API would pull it into
    /// memory. Headers are all we read. Uses URLSession even for interface-bound
    /// plans — the engine's initial probe already egresses the default route
    /// (pins govern payload bytes, not metadata probes).
    static func probeMidpointRange(plan: TransferPlan, total: Int64) async -> Bool {
        let box = StreamerBox()
        return await withTaskCancellationHandler {
            var req = makeRequest(plan.url, settings: plan.settings)
            let m = max(0, total / 2)
            req.setValue("bytes=\(m)-\(m)", forHTTPHeaderField: "Range")
            guard let (http, _, streamer) = try? await openStream(
                session: plan.session, request: req,
                // Close the cancel-vs-register race: a cancellation that fired
                // between the handler install and this registration found a nil
                // box (no-op); re-checking here — synchronously on the prober's
                // task, BEFORE openStream resumes the URLSession task — aborts it
                // so a cancelled prober never leaves a stray midpoint GET waiting
                // on headers (same reason ConnectionGovernor.acquire re-checks
                // under isolation).
                register: { box.set($0); if Task.isCancelled { box.cancel() } }
            ) else { return false }
            streamer.cancelTask()          // headers only — never drain the body
            guard http.statusCode == 206, contentRangeTotal(http) == total else { return false }
            // Probe edge of the validator triangle: the ranged tail must come from
            // the entity the plan's probe described. Same rule as a resume.
            return validatorsAllowResume(
                cursorETag: plan.etag, cursorLastModified: plan.lastModified,
                probeETag: http.value(forHTTPHeaderField: "ETag"),
                probeLastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        } onCancel: { box.cancel() }
    }

    /// Kill-the-stream → charge budget → re-enter the segmented phase with a
    /// synthesized layout (completed prefix + freshly-cut tail). `preallocate`
    /// EXTENDS the W-byte file to `total`, preserving the prefix — this path must
    /// never revisit the singles' `Data().write` truncation.
    private func upgradeToSegmented(total: Int64, written: Int64) async throws -> TransferOutcome {
        if written == total {
            // The trip landed on the stream's final flush: nothing left to segment.
            return TransferOutcome(bytesWritten: written, resumeData: nil, usedSegments: 1)
        }
        // The streamed 200 is a separate response with its own framing and can
        // be LONGER than the probed size (mid-deploy: edge A declared 10 MiB/v1,
        // edge B streamed 12 MiB/v2). Success is written == total ONLY; an
        // overshoot must fail exactly like runSingle's completeness net — never
        // be returned as `.completed`, and never reach preallocate (which would
        // truncate real bytes).
        guard written < total else {
            throw DownloadError.network("Incomplete download: wrote \(written) of \(total) bytes")
        }
        try Task.checkCancellation()                 // don't charge budget for a paused task
        let multiPath = plan.boundAdapters.count >= 2
        let minSegment: Int64 = multiPath ? 32 * 1024 : 64 * 1024
        // The transfer already holds 1 reserved connection, so it asks for
        // `sizeCap - 1` extras; the ENGINE owns profile/host/global clamping
        // inside the closure. A zero grant still upgrades (1 tail segment): the
        // download becomes resumable with cursors, which single-stream never was.
        let sizeCap = Self.clampSegmentCount(Self.upgradeMaxConnections,
                                             total: total - written, minSegment: minSegment)
        let granted = await plan.requestExtraConnections?(max(0, sizeCap - 1)) ?? 0
        // Fan-out is 1 + granted, never inflated to the adapter count: opening
        // more segments than the budget charged would falsify the engine's
        // accounting. If granted < adapters−1, a NIC idles; budget wins.
        let layout = Self.upgradedLayout(total: total, written: written,
                                         connections: 1 + granted, minSegment: minSegment)
        let streams = layout.ranges.count - (written > 0 ? 1 : 0)
        GoelLog.engineHTTP.notice("Range support appeared mid-download; upgrading to segmented",
            .count(streams, label: "connections"),
            .bytes(written, label: "written"),
            .bytes(total, label: "total"),
            .url(plan.url))
        return try await runSegmented(total: total, ranges: layout.ranges,
                                      restored: layout.restored, upgraded: true)
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
        #if os(Linux)
        // swift-corelibs-foundation does not honour the per-task
        // `URLSessionTask.delegate`; only a SESSION-level delegate receives
        // `didReceive(response:)` / `didReceive(data:)`. Without this the segmented
        // transfer would attach its `ChunkStreamer` to the task, get no callbacks,
        // and write zero bytes. This used to mean a session per stream, which is
        // one `URLSession` deallocation per segment — and freeing a corelibs
        // session can abort the process (see ``SessionPool``). One kept-forever
        // session carries every stream instead, with a router fanning the
        // session-level callbacks back out to the streamer that owns each task.
        let config = session.configuration
        let streamSession = SessionPool.session(
            key: "segment-stream/"
               + SessionPool.proxyKey(config.connectionProxyDictionary as? [String: Any])
        ) {
            URLSession(configuration: config, delegate: StreamRouter.shared, delegateQueue: nil)
        }
        let task = streamSession.dataTask(with: request)
        StreamRouter.shared.attach(streamer, to: task)
        #else
        let task = session.dataTask(with: request)
        task.delegate = streamer
        #endif
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

    /// The accept / retry / reject decision for a freshly-opened response,
    /// shared by the segmented and single-stream pumps so the acceptance rule
    /// cannot drift between them.
    enum StatusClass: Equatable { case accept, retry, reject }

    /// Curl says "Could not connect to server" without saying through *what*. An
    /// interface with an address but a dead upstream is a common multi-NIC state,
    /// and naming it is the difference between a fixable report and a mystery.
    static func transportError(_ curlCode: Int, via adapter: BoundAdapter?) -> String {
        let message = String(cString: gcb_error_message(Int32(curlCode)))
        guard let adapter else { return message }
        return "\(message) (via \(adapter.label))"
    }

    /// Classify a response status for the pump about to read its body. A ranged
    /// (segmented) pump accepts ONLY `206` — a `200` full body would make every
    /// segment write the whole file at its own offset and corrupt the result; a
    /// single-stream pump accepts any `2xx`. Retryable statuses (rate-limit /
    /// gateway errors) are `.retry` regardless of mode; everything else `.reject`.
    static func classify(_ status: Int, ranged: Bool) -> StatusClass {
        if isRetryableStatus(status) { return .retry }
        let accepted = ranged ? (status == 206) : (200..<300).contains(status)
        return accepted ? .accept : .reject
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
        // The size is a parsed server header, so it can be negative; `UInt64(size)`
        // below would trap on it. Refuse the transfer instead of dying.
        guard size >= 0 else {
            throw DownloadError.network("Server declared an impossible size (\(size) bytes)")
        }
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

    /// Is the destination still the preallocated file the cursor describes?
    ///
    /// A ``ResumeCursor`` records how many bytes of each range were fetched, but the
    /// bytes themselves live in the destination file — and the segmented path is the
    /// only one that resumes from a side-channel record instead of the on-disk size
    /// (see ``RemoteTransferPrep/openForResume``). If the partial file was deleted,
    /// moved or replaced while the download was paused, ``preallocate`` would silently
    /// recreate it, every "already done" range would be skipped, and the resulting
    /// mostly-zero file would still satisfy the `bytesWritten == total` net and be
    /// reported as `.completed`. So require the file to exist at exactly the size
    /// ``preallocate`` gave it; anything else falls through to a fresh start.
    static func destinationHoldsPreallocation(_ url: URL, total: Int64) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.int64Value else { return false }
        return size == total
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
        /// Declared size of the whole transfer, when the server gave one. The
        /// segmented path also carries it in ``meta``; the single-stream path has
        /// no range plan, so this is the only way it can report a real progress
        /// fraction for its one connection row (nil when the size is unknown).
        private let expectedTotal: Int64?
        private var segmentBytes: [Int: Int64]
        /// Running sum of `segmentBytes` — O(1) total instead of reduce-per-flush.
        private var runningTotal: Int64 = 0
        /// Constant for a download's lifetime (the live fan-out reported to the UI).
        private let connectionCount: Int
        /// Multi-path adapter labels per segment index (bsdName / display).
        private var segmentAdapters: [Int: (id: String, label: String)] = [:]
        /// Two-point speed window: the time and byte count at the previous emit.
        private var lastEmit = Date.distantPast
        private var lastEmitBytes: Int64 = 0
        private var lastResumeEmit = Date.distantPast
        /// Per-segment two-point speed window for the ~1 Hz connections snapshot.
        private var lastConnectionsEmit = Date.distantPast
        private var lastConnectionsBytes: [Int: Int64] = [:]

        init(continuation: AsyncStream<TransferProgress>.Continuation, meta: CursorMeta?,
             initialSegmentBytes: [Int: Int64], connectionCount: Int, expectedTotal: Int64?) {
            self.continuation = continuation
            self.meta = meta
            self.segmentBytes = initialSegmentBytes
            self.runningTotal = initialSegmentBytes.values.reduce(0, +)
            self.connectionCount = connectionCount
            self.expectedTotal = expectedTotal
        }

        func setAdapter(segment: Int, id: String, label: String) {
            segmentAdapters[segment] = (id, label)
        }

        func totalBytes() -> Int64 { runningTotal }

        /// Record `n` flushed bytes for `segment` and, when the throttle allows,
        /// yield a progress tick (with a fresh resume cursor at most once a second).
        func advance(segment: Int, by n: Int) {
            segmentBytes[segment, default: 0] += Int64(n)
            runningTotal += Int64(n)
            let total = runningTotal

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
                // Single stream: the one row *is* the whole transfer, so its
                // progress is the overall fraction. (It used to report a constant
                // 0%, which read as a stalled connection while the download was
                // plainly advancing.) A size-unknown stream has no fraction to
                // report and honestly stays at 0.
                let done = segmentBytes[0] ?? 0
                let fraction = (expectedTotal ?? 0) > 0
                    ? min(1, Double(done) / Double(expectedTotal!)) : 0
                let detail = (expectedTotal ?? 0) > 0
                    ? "single stream · \(Self.byteLabel(done)) of \(Self.byteLabel(expectedTotal!))"
                    : "single stream · \(Self.byteLabel(done))"
                return [TaskConnection(
                    id: "seg-0", label: "Connection 1", detail: detail,
                    downloadSpeed: overallSpeed, progress: fraction)]
            }
            return meta.ranges.indices.map { i in
                let range = meta.ranges[i]
                let length = range.end - range.start + 1
                let done = segmentBytes[i] ?? 0
                let speed = dt < 3600 ? Double(done - (lastConnectionsBytes[i] ?? 0)) / dt : 0
                let adapter = segmentAdapters[i]
                return TaskConnection(
                    id: "seg-\(i)",
                    label: "Segment \(i + 1)",
                    detail: "\(Self.byteLabel(range.start)) – \(Self.byteLabel(range.end + 1))",
                    downloadSpeed: max(0, speed),
                    progress: length > 0 ? min(1, Double(done) / Double(length)) : 0,
                    adapterId: adapter?.id,
                    adapterLabel: adapter?.label)
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
    /// This download's OWN speed limit (0 = uncapped). The profile-wide ceiling
    /// rides on ``sharedLimiter`` instead, so it can hold across downloads.
    var maxBytesPerSecond: Int64
    /// The caller's engine-wide download pacer, shared by every concurrent
    /// transfer so the profile's cap holds in sum rather than per download.
    var sharedLimiter: RateLimiter? = nil
    var flushSize: Int
    /// Alternative URLs for the same bytes. Only the segmented path uses them
    /// (a 206's Content-Range total proves a mirror serves the same file; the
    /// single-stream path has no such check, so it stays on the primary).
    var mirrors: [URL] = []
    /// When non-empty **and** ranges are used, segments bind to these adapters
    /// via CurlBridge egress scoping (network aggregation). Empty ⇒ URLSession path.
    var boundAdapters: [BoundAdapter] = []
    /// Connect timeout forwarded to bound HTTP (seconds).
    var connectTimeout: Double = 30
    /// Mid-flight range re-probe cadence (see ``UpgradeProbing``).
    var upgradeProbing = UpgradeProbing()
    /// Engine-supplied channel to charge additional connections against the
    /// cross-download budget mid-flight. Receives the wanted count, returns the
    /// granted count (0...wanted). nil (tests, non-engine callers) disables the
    /// mid-flight upgrade entirely.
    var requestExtraConnections: (@Sendable (Int) async -> Int)? = nil
}

/// Mid-flight range re-probe cadence. Exists as data so tests can compress the
/// schedule; production always runs the defaults.
struct UpgradeProbing: Sendable {
    var initialDelay: TimeInterval = 10
    var interval: TimeInterval = 30
    var maxAttempts: Int = 5
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
#if os(Linux)
/// Fans one session's delegate callbacks out to the ``ChunkStreamer`` that owns
/// each task.
///
/// swift-corelibs-foundation ignores `URLSessionTask.delegate`, so the delegate
/// must live on the session — but a session per stream means a `URLSession`
/// deallocation per segment, and freeing one can abort the process (see
/// ``SessionPool``). Task identifiers are unique within a session, which is what
/// makes a single shared session with this router equivalent.
final class StreamRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamRouter()

    private let lock = NSLock()
    private var streamers: [Int: ChunkStreamer] = [:]

    /// Must run before `task.resume()`, or the first callback finds no streamer.
    func attach(_ streamer: ChunkStreamer, to task: URLSessionTask) {
        lock.lock(); streamers[task.taskIdentifier] = streamer; lock.unlock()
    }

    private func find(_ task: URLSessionTask) -> ChunkStreamer? {
        lock.lock(); defer { lock.unlock() }
        return streamers[task.taskIdentifier]
    }

    private func remove(_ task: URLSessionTask) -> ChunkStreamer? {
        lock.lock(); defer { lock.unlock() }
        return streamers.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let streamer = find(dataTask) else { completionHandler(.cancel); return }
        streamer.urlSession(session, dataTask: dataTask, didReceive: response,
                            completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        find(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        remove(task)?.urlSession(session, task: task, didCompleteWithError: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let streamer = find(task) else { completionHandler(nil); return }
        streamer.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: request, completionHandler: completionHandler)
    }
}
#endif

final class ChunkStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseCont: CheckedContinuation<HTTPURLResponse, Error>?
    private var bodyCont: AsyncThrowingStream<Data, Error>.Continuation?
    private weak var task: URLSessionTask?
    private var outstanding = 0
    private var suspended = false
    private var done = false
    /// Why the task finished, kept so a continuation that arrives after
    /// completion can be resumed with the real cause instead of hanging.
    private var completionError: Error?

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
    /// Registering a continuation on a streamer whose task ALREADY completed must
    /// resume it here: `didCompleteWithError` has run and will never fire again, so
    /// parking it would suspend the caller forever. A cancellation landing between
    /// `register` (which may abort the task) and this call makes that window
    /// reachable by construction, not by luck.
    func setResponseContinuation(_ cont: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.lock()
        if done {
            let error = completionError
            lock.unlock()
            cont.resume(throwing: error ?? DownloadError.network("No HTTP response"))
            return
        }
        responseCont = cont
        lock.unlock()
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
        // `suspend()` MUST happen under the same lock that publishes `suspended`.
        // Doing it after the unlock opens a lost-wakeup window: the consumer runs
        // on the transfer's task, and it can drain below `lowWater`, observe
        // `suspended == true`, clear it and call `resume()` on a task that has not
        // suspended yet (a no-op) — after which our `suspend()` lands and nothing
        // is left to undo it, stalling the segment forever. `consumed(_:)` calls
        // `resume()` outside the lock and takes no other lock, so there is no
        // inversion to deadlock against.
        if !suspended && outstanding >= highWater {
            suspended = true
            dataTask.suspend()
        }
        let cont = bodyCont
        lock.unlock()
        cont?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let rcont = responseCont; responseCont = nil
        let bcont = bodyCont; bodyCont = nil
        done = true
        completionError = error ?? DownloadError.network("No HTTP response")
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
        // A server-initiated redirect to a different host (or an https→http
        // downgrade) must not carry the user's per-task secrets to whoever the new
        // host is: this strips Authorization, Referer, Cookie AND every custom
        // per-task header (API keys etc.), keeping only neutral transport headers.
        // It also refuses the hop outright when the new host is loopback or the
        // link-local/metadata range — a `Location` is chosen by the server, so
        // following it blindly turns any download into an SSRF primitive.
        completionHandler(RedirectSanitizer.followed(request, originalURL: task.originalRequest?.url))
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

/// Trip-once flag between the upgrade prober and the byte pump. A lock, not an
/// actor: the pump reads it at every flush and must not hop executors to do so.
final class UpgradeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() { lock.lock(); tripped = true; lock.unlock() }
    var isTripped: Bool { lock.lock(); defer { lock.unlock() }; return tripped }
}
