import Foundation
import CurlBridge

// MARK: - Segmented transfer

/// Per-download byte engine split from ``HTTPEngine`` for testability: segmented when ranges + size are
/// known, else one stream; cursors validated vs `ETag`/`Last-Modified`; owns no cross-download state.
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

    /// Connections this transfer opens; ``HTTPEngine`` reserves exactly this against the cross-download
    /// budget, since a restored cursor's range count may differ from ``TransferPlan/segmentCount``.
    var connectionCount: Int { segmented ? plannedRanges.count : 1 }

    init(plan: TransferPlan) {
        self.plan = plan
        var cont: AsyncStream<TransferProgress>.Continuation!
        self.progress = AsyncStream<TransferProgress> { cont = $0 }
        self.continuation = cont

        // Resolve segmented-vs-single up front (cursor decode/validate, range math, one `stat`) so the
        // caller can reserve `connectionCount`; a negative `totalBytes` is hostile → single stream.
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
           // Multi-path needs ≥1 range per adapter; a stale pre-aggregation single-segment resume would
           // pin everything to one NIC. Rejecting the upgrade's W==0 single-range cursors is harmless.
           !(multiPath && cursor.ranges.count < plan.boundAdapters.count
             && cursor.completed.allSatisfy { $0 == 0 }),
           // …and the cursor's claimed on-disk bytes must still be there (``destinationHoldsPreallocation``).
           // Checked last: the only condition that touches the filesystem.
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

    /// Run to completion; single vs segmented comes purely from the plan's flags (no size or no ranges
    /// -> single). The progress stream is always finished on exit so `for await` terminates either way.
    func run() async throws -> TransferOutcome {
        defer { continuation.finish() }
        // `segmented` is only set alongside a present, non-negative `totalBytes`; binding it here says
        // so in the type system instead of force-unwrapping a value parsed from a server header.
        guard segmented, let total = plan.totalBytes else {
            // Pinned to an interface but unsplittable: URLSession cannot bind, so the whole body takes
            // the curl path rather than silently ignoring the pin and egressing the default route.
            if let adapter = plan.boundAdapters.first {
                return try await runSingleBound(adapter)
            }
            return try await runSingle()
        }
        return try await runSegmented(total: total, ranges: plannedRanges,
                                      restored: restoredBytes, upgraded: false)
    }

    // MARK: Pacing

    /// Pacer for this transfer's flushes: the task's own cap chained in front of the engine-wide one,
    /// so the profile ceiling holds in SUM across downloads. nil = unlimited; `static` so it's assertable.
    static func makeLimiter(_ plan: TransferPlan) -> RateLimiter? {
        guard plan.maxBytesPerSecond > 0 else { return plan.sharedLimiter }
        return RateLimiter(bytesPerSecond: plan.maxBytesPerSecond, next: plan.sharedLimiter)
    }

    // MARK: Segmented download

    /// `ranges`/`restored` are the init-resolved layout; the mid-flight upgrade instead passes a
    /// synthesized one (completed prefix + fresh tail) with `upgraded: true`, arming the ranged-200 retry.
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
        // Segments round-robin across primary + mirrors; misbehaving mirrors are demoted. An UPGRADED
        // transfer stays on the primary: bytes [0, W-1] came from it, so a same-sized mirror would splice.
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
        // Aggregate completeness net: each segment verified its own range, but assert the whole file is
        // accounted for before reporting success so a silent gap can never be emitted as `.completed`.
        guard bytesWritten == total else {
            throw DownloadError.network("Incomplete download: wrote \(bytesWritten) of \(total) bytes")
        }
        let resumeData = await ledger.currentResumeData()
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: resumeData, usedSegments: ranges.count)
    }

    /// The byte pump runs OFF any actor (plain class) — otherwise every segment would serialize through
    /// an executor, one hop per byte. It hops to the ledger only once per ~`flushSize` flush.
    private func downloadSegment(session: URLSession, governor: ConnectionGovernor, limiter: RateLimiter?,
                                 ledger: Ledger, pool: MirrorPool, index: Int,
                                 from start: Int64, to end: Int64, fileURL: URL,
                                 upgraded: Bool) async throws {
        let settings = plan.settings
        let flushSize = plan.flushSize
        let handle = try FileHandle(forWritingTo: fileURL)
        // Bytes of THIS segment already flushed to disk this run. A retry resumes from `start + written`,
        // so progress is never double-counted and already-stored bytes are not re-fetched.
        var written: Int64 = 0
        var attempt = 0
        // Holds the in-flight request so the cancellation handler can abort the underlying URLSession
        // task (pause/remove), not merely the Swift task — the delegate body would keep draining.
        let streamerBox = StreamerBox()
        do {
            try await withTaskCancellationHandler {
                while start + written <= end {
                    try Task.checkCancellation()
                    attempt += 1
                    let segStart = start + written
                    let url = await pool.url(segment: index, attempt: attempt)
                    let isMirror = url != plan.url

                    // Wait for a connection slot; the governor adapts the ceiling to what the server
                    // tolerates. Each `acquire()` is balanced by exactly one `release()` on every exit.
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
                            // Range support flapped back mid-upgrade (cold edge). The probe
                            // just saw a 206, so a warm edge exists; retry with backoff.
                            streamer.cancelTask()                        // never drain the full body
                            if isMirror { await pool.demote(url) }
                            await governor.release()
                            try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                            continue
                        }
                        // A ranged GET answered non-206 (e.g. a full 200 body) is unusable for a
                        // segment; a mirror that can't range is demoted, the primary fails visibly.
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
                    // A clean `pumpBody` return does NOT prove the whole range arrived: a close-delimited
                    // or early-zero-chunk body ends without error, leaving a silent zero-byte gap.
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

    /// Same segment pump as ``downloadSegment`` but each attempt uses ``BoundHTTPClient`` (CurlBridge +
    /// IP_BOUND_IF / SO_BINDTODEVICE) to egress a chosen adapter; round-robin, demoted on bind failure.
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
                    // Global THEN adapter, always: a cancellation parked on the adapter
                    // governor must hand the claimed global slot back, or the slot leaks.
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

                    // curl's write callback cannot await, so it tallies and this pump folds bytes into
                    // the ledger every 200 ms; onBytes fires post-write, so the tally == bytes on disk.
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
                        // Server ignored Range (flap-back); C aborted on the first body byte, so
                        // nothing was written. Retryable when upgraded or on a mirror; else terminal.
                        if isMirror { await pool.demote(url) }
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        if (upgraded || isMirror), attempt < settings.maxAttempts {
                            try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                            continue
                        }
                        throw DownloadError.httpStatus(200)
                    }

                    // Curl transport errors. The tally pump already credited the ledger (Σ onBytes ==
                    // bytesWritten); only the retry-resume offset commits here, so nothing is doubled.
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
                        // Per-IP pushback belongs to the path that got it: only this adapter's
                        // ceiling shrinks, so healthy NICs are never starved by one throttled source.
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
                        // Ranged-200 flap-back with an EMPTY body: C only sets `rangeIgnored` from the
                        // write thunk, so a zero-byte 200 lands here. Same answer — the probe saw 206.
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

                    // The ledger already holds these bytes via the tally pump; only the offset
                    // bookkeeping that the completeness check reads is committed here.
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
        // SF8: truncate to zero on (re)create — `createFile` no-ops when the file exists, leaving stale
        // trailing bytes if the new download is shorter. `Data().write` both creates and truncates.
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
        // When the server declared a size but no ranges, verify the whole body arrived: a close-delimited
        // stream can end cleanly while short, and reporting that `.completed` is silent truncation.
        if let total = plan.totalBytes, bytesWritten != total {
            throw DownloadError.network("Incomplete download: wrote \(bytesWritten) of \(total) bytes")
        }
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: nil, usedSegments: 1)
    }

    /// Single-connection download pinned to one interface (no size / no ranges). Uses CurlBridge, as
    /// `URLSession` has no `SO_BINDTODEVICE`; only connect/status retries — bytes on disk are terminal.
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
        // All three of BoundHTTPClient's abort consumers read the trip, so whichever runs first stops
        // curl; `Response.aborted` re-reads the closure, which is what makes the trip unmissable.
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
                // Signal-abort is an upgrade; task-cancellation abort stays a pause/remove.
                // If both raced, cancellation wins — the engine's pause owns the transition.
                if let upgrade, upgrade.signal.isTripped, !Task.isCancelled {
                    try handle.close()                       // flush failure = real failure
                    let written = await ledger.totalBytes()
                    switch Self.classify(response.httpStatus, ranged: false) {
                    case .accept:
                        // Stream edge of the validator triangle: probe (URLSession/gzip) and stream
                        // (curl/identity) see different ETags, so a mismatch drops the prefix, not the run.
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
                        // The unranged GET is being 429/5xx'd while ranges just probed 206:
                        // upgrading IS the retry. written == 0 (error bodies drain in C).
                        return try await upgradeToSegmented(total: upgrade.total, written: written)
                    case .reject:
                        if response.httpStatus == 0 {
                            // Tripped during connect, before any response arrived:
                            // nothing on disk (written == 0), no status to honour.
                            return try await upgradeToSegmented(total: upgrade.total, written: written)
                        }
                        // A terminal status (401/403/404…) surfaces as itself rather than being
                        // laundered through an upgrade whose segments would re-fail on the same host.
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
            // Retry only the connect/status phase: the no-range fallback can't resume a partial body,
            // so a mid-stream drop is terminal (the body read sits outside this loop deliberately).
            var result: (HTTPURLResponse, AsyncThrowingStream<Data, Error>, ChunkStreamer)?
            var attempt = 0
            while true {
                try Task.checkCancellation()
                // A stream stuck in connect/status retries (503 on the unranged GET while ranges
                // 206) must still honour a trip — W == 0, so there is no entity edge to verify.
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

            // The streaming 200 must be the entity the probe described, so the prefix and any ranged
            // tail share one representation. On mismatch only the upgrade is disabled, not the stream.
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
                // The upgrade is the one error path whose on-disk bytes are KEPT as a completed prefix
                // segment, so a close(2) failure would leave an invisible hole: flush failure = failure.
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

    /// Drain `bytes` into `handle`, flushing every `flushSize` and folding each flush into `ledger`
    /// (under `segment`) and `limiter`. `written` updates incrementally so a mid-body throw can resume.
    private func pumpBody(_ bytes: AsyncThrowingStream<Data, Error>, into handle: FileHandle,
                          streamer: ChunkStreamer, ledger: Ledger, segment: Int,
                          limiter: RateLimiter?, flushSize: Int, written: inout Int64,
                          upgrade: UpgradeSignal? = nil) async throws {
        // Body arrives as `Data` chunks from the task delegate (not per-byte `await`), so appends are
        // memcpys and the loop isn't CPU-bound. `consumed` releases backpressure credit per chunk.
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
                // Pace against the profile's aggregate download cap. The pacer behind this one is
                // shared across all segments AND all downloads, so combined throughput hits the cap.
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

    /// Layout for a single stream upgrading to segments: completed prefix [0, written) restored as
    /// segment 0 (omitted when nothing flushed), remainder cut with a fresh plan's clamp math.
    static func upgradedLayout(total: Int64, written: Int64, connections: Int,
                               minSegment: Int64 = 64 * 1024) -> (ranges: [Range64], restored: [Int: Int64]) {
        let remainder = max(0, total - written)
        let count = clampSegmentCount(max(1, connections), total: remainder, minSegment: minSegment)
        let tail = makeRanges(total: remainder, count: count)
            .map { Range64(start: $0.start + written, end: $0.end + written) }
        guard written > 0 else { return (tail, [:]) }
        return ([Range64(start: 0, end: written - 1)] + tail, [0: written])
    }

    /// nil when the plan can never upgrade (gate fails, or no engine budget channel — so plans built
    /// without the closure behave bit-for-bit as before). Caller owns `defer { upgrade?.task.cancel() }`.
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

    /// One ranged header probe at the file midpoint. MUST use openStream + cancelTask: a server that
    /// ignores Range answers 200 with the WHOLE body. URLSession even for bound plans (metadata, not payload).
    static func probeMidpointRange(plan: TransferPlan, total: Int64) async -> Bool {
        let box = StreamerBox()
        return await withTaskCancellationHandler {
            var req = makeRequest(plan.url, settings: plan.settings)
            let m = max(0, total / 2)
            req.setValue("bytes=\(m)-\(m)", forHTTPHeaderField: "Range")
            guard let (http, _, streamer) = try? await openStream(
                session: plan.session, request: req,
                // Close the cancel-vs-register race: re-check here, synchronously and BEFORE
                // openStream resumes the task, so a cancelled prober leaves no stray midpoint GET.
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

    /// Kill the stream → charge budget → re-enter segmented with a synthesized layout. `preallocate`
    /// EXTENDS the W-byte file to `total`, preserving the prefix — never the singles' `Data().write`.
    private func upgradeToSegmented(total: Int64, written: Int64) async throws -> TransferOutcome {
        if written == total {
            // The trip landed on the stream's final flush: nothing left to segment.
            return TransferOutcome(bytesWritten: written, resumeData: nil, usedSegments: 1)
        }
        // The streamed 200 has its own framing and can be LONGER than the probed size (mid-deploy edge
        // skew). Success is written == total ONLY; an overshoot must fail, never reach preallocate.
        guard written < total else {
            throw DownloadError.network("Incomplete download: wrote \(written) of \(total) bytes")
        }
        try Task.checkCancellation()                 // don't charge budget for a paused task
        let multiPath = plan.boundAdapters.count >= 2
        let minSegment: Int64 = multiPath ? 32 * 1024 : 64 * 1024
        // The transfer already holds 1 reserved connection, so it asks for `sizeCap - 1` extras; the
        // ENGINE clamps. A zero grant still upgrades (1 tail segment) — cursors make it resumable.
        let sizeCap = Self.clampSegmentCount(Self.upgradeMaxConnections,
                                             total: total - written, minSegment: minSegment)
        let granted = await plan.requestExtraConnections?(max(0, sizeCap - 1)) ?? 0
        // Fan-out is 1 + granted, never inflated to the adapter count: opening more segments than the
        // budget charged would falsify engine accounting. If granted < adapters−1 a NIC idles.
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

    /// Builds a request carrying the client `User-Agent` (plus preemptive `Authorization`). ALL outbound
    /// requests go through here: a missing UA makes some CDNs/WAFs reset the connection, seen as -1005.
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

    /// A request for any pool URL. The stored `Authorization` was resolved for the PRIMARY host and must
    /// never ride to a mirror on another host — that hands the user's credentials to its operator.
    private func request(for url: URL) -> URLRequest {
        var settings = plan.settings
        // Authorization / Referer / custom headers were resolved for the PRIMARY host; none may ride to
        // a mirror on a different host (leaking the user's credentials/context to its operator).
        if url.host?.lowercased() != plan.url.host?.lowercased() {
            settings.authorization = nil
            settings.referer = nil
            settings.extraHeaders = [:]
        }
        return Self.makeRequest(url, settings: settings)
    }

    /// Open `request`, returning headers, a stream of body `Data` chunks and its ``ChunkStreamer``:
    /// `URLSession.bytes` is per-byte CPU-bound. `register` runs before the task starts, so cancel works.
    static func openStream(
        session: URLSession, request: URLRequest,
        register: (ChunkStreamer) -> Void
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, ChunkStreamer) {
        let streamer = ChunkStreamer()
        var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        let body = AsyncThrowingStream<Data, Error> { bodyContinuation = $0 }
        #if os(Linux)
        // swift-corelibs-foundation ignores per-task delegates — only a SESSION delegate gets callbacks,
        // and freeing a corelibs session can abort the process, so one kept session routes every stream.
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

    /// The accept / retry / reject decision for a freshly-opened response, shared by the segmented and
    /// single-stream pumps so the acceptance rule cannot drift between them.
    enum StatusClass: Equatable { case accept, retry, reject }

    /// Curl says "Could not connect to server" without saying through *what*. An interface with an
    /// address but a dead upstream is a common multi-NIC state; naming it makes the report fixable.
    static func transportError(_ curlCode: Int, via adapter: BoundAdapter?) -> String {
        let message = String(cString: gcb_error_message(Int32(curlCode)))
        guard let adapter else { return message }
        return "\(message) (via \(adapter.label))"
    }

    /// Classify a response status for the pump about to read its body: a ranged pump accepts ONLY `206`
    /// (a 200 full body would corrupt every offset), single-stream any `2xx`; retryables are `.retry`.
    static func classify(_ status: Int, ranged: Bool) -> StatusClass {
        if isRetryableStatus(status) { return .retry }
        let accepted = ranged ? (status == 206) : (200..<300).contains(status)
        return accepted ? .accept : .reject
    }

    /// Network errors a retry can plausibly recover from (dropped connection, timeout, transient host).
    /// Deliberately excludes `.cancelled` (our own pause/remove) and non-network errors (disk, etc.).
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

    /// Sleeps before the next attempt: numeric `Retry-After` when present, else exponential backoff with
    /// jitter (de-synchronises a rate-limited herd). `Task.sleep` throws, so pause/remove still interrupt.
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

    /// Pure, testable resume gate. With no `ETag` and no `Last-Modified` on either side nothing proves
    /// the remote is unchanged, so we DO NOT resume (a silent swap would corrupt) — we restart instead.
    static func validatorsAllowResume(
        cursorETag: String?, cursorLastModified: String?,
        probeETag: String?, probeLastModified: String?
    ) -> Bool {
        if let a = cursorETag, let b = probeETag { return a == b }
        if let a = cursorLastModified, let b = probeLastModified { return a == b }
        return false
    }

    /// Is the destination still the preallocated file the cursor describes? A deleted/moved partial gets
    /// silently recreated by ``preallocate``, so a mostly-zero file would pass the net as `.completed`.
    static func destinationHoldsPreallocation(_ url: URL, total: Int64) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.int64Value else { return false }
        return size == total
    }

    /// Guard a decoded cursor before trusting its ranges/offsets for seeks: corruption must force a fresh
    /// start, never an out-of-bounds seek (a negative offset traps `UInt64(_:)`). Checks bounds and counts.
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

    /// Distributes segments across primary + mirrors and tracks misbehaving ones. Demoted URLs are
    /// skipped; if all are demoted the slate is wiped — the pool must never go empty.
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

    /// The single point of mutable transfer state. Pumps hop here once per flush to accumulate segment
    /// bytes, build the cursor and throttle progress — the hot path stays off shared executors.
    private actor Ledger {
        private let continuation: AsyncStream<TransferProgress>.Continuation
        private let meta: CursorMeta?
        /// Declared size of the whole transfer when the server gave one. The single-stream path has no
        /// range plan, so this is its only way to report a real progress fraction (nil if unknown).
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

        /// A per-segment snapshot for the detail panel's Connections/Progress tabs, throttled to ~1 Hz.
        /// Single-stream transfers (no range plan) report one connection row.
        private func maybeConnections(now: Date, overallSpeed: Double) -> [TaskConnection]? {
            let dt = now.timeIntervalSince(lastConnectionsEmit)
            guard dt >= 1.0 else { return nil }
            defer {
                lastConnectionsEmit = now
                lastConnectionsBytes = segmentBytes
            }
            guard let meta else {
                // Single stream: the one row *is* the whole transfer, so its progress is the overall
                // fraction (it used to sit at a constant 0%, reading as stalled). Unknown size stays 0.
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
    /// Alternative URLs for the same bytes. Only the segmented path uses them (a 206's Content-Range
    /// total proves a mirror serves the same file; single-stream has no such check, so it stays put).
    var mirrors: [URL] = []
    /// When non-empty **and** ranges are used, segments bind to these adapters
    /// via CurlBridge egress scoping (network aggregation). Empty ⇒ URLSession path.
    var boundAdapters: [BoundAdapter] = []
    /// Connect timeout forwarded to bound HTTP (seconds).
    var connectTimeout: Double = 30
    /// Mid-flight range re-probe cadence (see ``UpgradeProbing``).
    var upgradeProbing = UpgradeProbing()
    /// Engine-supplied channel to charge extra connections against the cross-download budget mid-flight;
    /// takes the wanted count, returns granted (0...wanted). nil (tests) disables the upgrade entirely.
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

/// Turns `URLSessionDataTask` delegate callbacks into an `AsyncThrowingStream<Data>` — `URLSession.bytes`
/// is per-byte CPU-bound. Watermarks give TCP backpressure; redirects strip cross-host auth; `lock` guards.
#if os(Linux)
/// Fans one session's delegate callbacks out to the ``ChunkStreamer`` that owns each task: corelibs
/// ignores `URLSessionTask.delegate`, and freeing a per-stream session can abort (see ``SessionPool``).
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

    /// Register the response continuation; after this the task may be resumed. If the task ALREADY
    /// completed, resume here — `didCompleteWithError` will never fire again and parking hangs forever.
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
        // `suspend()` MUST happen under the lock that publishes `suspended`, else a consumer can drain,
        // clear the flag and `resume()` a not-yet-suspended task — lost wakeup, the segment stalls.
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
        // A redirect to another host (or an https→http downgrade) must not carry per-task secrets: strip
        // Authorization/Referer/Cookie/custom headers, and refuse loopback + link-local — else SSRF.
        completionHandler(RedirectSanitizer.followed(request, originalURL: task.originalRequest?.url))
    }
}

/// A thread-safe holder for a segment's currently-active ``ChunkStreamer``, so a task-cancellation
/// handler can abort whichever request is in flight (each retry attempt swaps in a fresh streamer).
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
