import Foundation
import CurlBridge

final class SegmentedTransfer: Sendable {

    let plan: TransferPlan

    let progress: AsyncStream<TransferProgress>
    private let continuation: AsyncStream<TransferProgress>.Continuation

    private let segmented: Bool
    private let plannedRanges: [Range64]
    private let restoredBytes: [Int: Int64]

    /// Reserve exactly this: a restored cursor's range count may differ from `plan.segmentCount`.
    var connectionCount: Int { segmented ? plannedRanges.count : 1 }

    init(plan: TransferPlan) {
        self.plan = plan
        var cont: AsyncStream<TransferProgress>.Continuation!
        self.progress = AsyncStream<TransferProgress> { cont = $0 }
        self.continuation = cont

        // A negative `totalBytes` is hostile server input → single stream.
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

        let rejection = Self.resumeRejection(plan: plan, total: total, multiPath: multiPath)
        if let data = plan.existingResume, rejection == nil,
           let cursor = try? JSONDecoder().decode(ResumeCursor.self, from: data) {
            self.segmented = true
            self.plannedRanges = cursor.ranges
            self.restoredBytes = Dictionary(
                uniqueKeysWithValues: cursor.completed.enumerated().map { ($0.offset, $0.element) })
        } else {
            if plan.existingResume != nil, let rejection {
                // A silent restart at 0% on a 30 GB file is indistinguishable from a bug without this.
                GoelLog.engineHTTP.notice("Resume cursor discarded; restarting from 0",
                                          .detail(rejection.rawValue), .url(plan.url))
            }
            self.segmented = true
            let count = multiPath
                ? Self.clampSegmentCount(wanted, total: total, minSegment: 32 * 1024)
                : Self.clampSegmentCount(wanted, total: total)
            self.plannedRanges = Self.makeRanges(total: total, count: count)
            self.restoredBytes = [:]
        }
    }

    enum ResumeRejection: String, Equatable {
        case undecodable = "cursor is unreadable"
        case sizeChanged = "server reports a different size"
        case malformed = "cursor ranges don't describe the file"
        case unprovable = "server can't prove the file is unchanged (no matching ETag or Last-Modified)"
        case tooFewRanges = "cursor has fewer ranges than bound adapters"
        case partialMissing = "partial file is missing or the wrong size"
    }

    /// nil = the cursor is safe to adopt; otherwise the FIRST guard that failed, so the restart can be explained.
    static func resumeRejection(plan: TransferPlan, total: Int64, multiPath: Bool) -> ResumeRejection? {
        guard let data = plan.existingResume,
              let cursor = try? JSONDecoder().decode(ResumeCursor.self, from: data) else { return .undecodable }
        guard cursor.totalBytes == total else { return .sizeChanged }
        guard cursorIsWellFormed(cursor, total: total) else { return .malformed }
        guard validatorsAllowResume(
            cursorETag: cursor.etag, cursorLastModified: cursor.lastModified,
            probeETag: plan.etag, probeLastModified: plan.lastModified) else { return .unprovable }
        // Multi-path needs ≥1 range per adapter, else a stale cursor pins everything to one NIC.
        if multiPath && cursor.ranges.count < plan.boundAdapters.count
            && cursor.completed.allSatisfy({ $0 == 0 }) { return .tooFewRanges }
        guard destinationHoldsPreallocation(plan.destination, total: total) else { return .partialMissing }
        return nil
    }

    /// The progress stream must always be finished on exit, or `for await` never terminates.
    func run() async throws -> TransferOutcome {
        defer { continuation.finish() }
        guard segmented, let total = plan.totalBytes else {
            // URLSession cannot bind, so a pinned body takes the curl path rather than the default route.
            if let adapter = plan.boundAdapters.first {
                return try await runSingleBound(adapter)
            }
            return try await runSingle()
        }
        return try await runSegmented(total: total, ranges: plannedRanges,
                                      restored: restoredBytes, upgraded: false)
    }

    /// The task cap chains in front of the shared one, so the profile ceiling holds in SUM.
    static func makeLimiter(_ plan: TransferPlan) -> RateLimiter? {
        guard plan.maxBytesPerSecond > 0 else { return plan.sharedLimiter }
        return RateLimiter(bytesPerSecond: plan.maxBytesPerSecond, next: plan.sharedLimiter)
    }

    private func runSegmented(total: Int64, ranges: [Range64],
                              restored: [Int: Int64], upgraded: Bool) async throws -> TransferOutcome {
        try Self.preallocate(plan.destination, size: total)

        let initialBytes = Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, restored[$0] ?? 0) })
        let meta = CursorMeta(etag: plan.etag, lastModified: plan.lastModified, total: total, ranges: ranges)
        let durability = try DurabilityBarrier(plan.destination)
        defer { durability.close() }
        let ledger = Ledger(continuation: continuation, meta: meta,
                            initialSegmentBytes: initialBytes, connectionCount: ranges.count,
                            expectedTotal: total, durability: durability)

        let limiter = Self.makeLimiter(plan)
        let session = plan.session
        let governor = ConnectionGovernor(limit: ranges.count)
        // An UPGRADED transfer stays on the primary: bytes [0, W-1] came from it, a mirror would splice.
        let pool = MirrorPool(primary: plan.url, mirrors: upgraded ? [] : plan.mirrors)
        // One adapter is a valid plan — a task pinned to a single NIC still has to egress it.
        let adapterPool: AdapterPool? = plan.boundAdapters.isEmpty
            ? nil : AdapterPool(plan.boundAdapters)
        let adapterGovernors: AdapterGovernors? = plan.boundAdapters.isEmpty
            ? nil : AdapterGovernors(adapters: plan.boundAdapters, limit: ranges.count)
        if let adapterPool {
            for i in ranges.indices {
                if let a = await adapterPool.assign(segment: i) {
                    await ledger.setAdapter(segment: i, id: a.bsdName, label: a.label)
                }
            }
        }

        do {
            try await runSegments(ranges: ranges, initialBytes: initialBytes, ledger: ledger,
                                  limiter: limiter, session: session, governor: governor, pool: pool,
                                  adapterPool: adapterPool, adapterGovernors: adapterGovernors,
                                  upgraded: upgraded)
        } catch {
            // Every writer has returned, so the ledger is exact: publish it or a pause re-fetches up to 5 s.
            await ledger.publishFinalCursor()
            throw error
        }

        let bytesWritten = await ledger.totalBytes()
        // Assert the whole file is accounted for, so a silent gap can't be emitted as `.completed`.
        guard bytesWritten == total else {
            throw DownloadError.network("Incomplete download: wrote \(bytesWritten) of \(total) bytes")
        }
        let resumeData = await ledger.currentResumeData()
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: resumeData, usedSegments: ranges.count)
    }

    private func runSegments(ranges: [Range64], initialBytes: [Int: Int64], ledger: Ledger,
                             limiter: RateLimiter?, session: URLSession, governor: ConnectionGovernor,
                             pool: MirrorPool, adapterPool: AdapterPool?,
                             adapterGovernors: AdapterGovernors?, upgraded: Bool) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, range) in ranges.enumerated() {
                let already = initialBytes[i] ?? 0
                let segStart = range.start + already
                if segStart > range.end { continue }
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
    }

    /// Runs OFF any actor: on one, every segment would serialize through an executor, one hop per byte.
    private func downloadSegment(session: URLSession, governor: ConnectionGovernor, limiter: RateLimiter?,
                                 ledger: Ledger, pool: MirrorPool, index: Int,
                                 from start: Int64, to end: Int64, fileURL: URL,
                                 upgraded: Bool) async throws {
        let settings = plan.settings
        let flushSize = plan.flushSize
        let handle = try FileHandle(forWritingTo: fileURL)
        // Bytes of THIS segment flushed this run; a retry resumes at `start + written`, never doubling.
        var written: Int64 = 0
        var attempt = 0
        var progressMark: Int64 = 0
        // Set once a node answers our If-Range with the same bytes under its own ETag (load-balanced origins).
        var ifRangeDistrusted = false
        // Lets the cancel handler abort the URLSession task, not just the Swift one — else it keeps draining.
        let streamerBox = StreamerBox()
        do {
            try await withTaskCancellationHandler {
                while start + written <= end {
                    try Task.checkCancellation()
                    // The budget counts STALLED attempts: a flaky link that keeps making progress must not run out.
                    if written > progressMark { progressMark = written; attempt = 0 }
                    attempt += 1
                    let segStart = start + written
                    let url = await pool.url(segment: index, attempt: attempt)
                    let isMirror = url != plan.url
                    // A mirror's validators are its own; only the primary can be held to the probed entity.
                    let ifRange = (isMirror || ifRangeDistrusted) ? nil : Self.strongETag(plan.etag)

                    // Each `acquire()` must be balanced by exactly one `release()` on every exit path.
                    try await governor.acquire()
                    var req = request(for: url)
                    req.setValue("bytes=\(segStart)-\(end)", forHTTPHeaderField: "Range")
                    if let ifRange { req.setValue(ifRange, forHTTPHeaderField: "If-Range") }

                    let bytes: AsyncThrowingStream<Data, Error>
                    let http: HTTPURLResponse
                    let streamer: ChunkStreamer
                    do {
                        // Re-check synchronously BEFORE resume, or a cancelled segment still opens a request.
                        (http, bytes, streamer) = try await Self.openStream(
                            session: session, request: req,
                            register: { streamerBox.set($0); if Task.isCancelled { streamerBox.cancel() } })
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
                        streamer.cancelTask()
                        if isMirror { await pool.demote(url) }
                        await governor.throttleDown()
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.httpStatus(http.statusCode) }
                        try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                        continue
                    case .reject:
                        if upgraded, http.statusCode == 200, attempt < settings.maxAttempts {
                            // Range flapped back mid-upgrade; the probe saw 206, so a warm edge exists.
                            streamer.cancelTask()                        // never drain the full body
                            if isMirror { await pool.demote(url) }
                            await governor.release()
                            try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                            continue
                        }
                        // A ranged GET answered non-206 (a full 200 body) is unusable for a segment.
                        streamer.cancelTask()
                        await governor.release()
                        // With If-Range, a 200 is the server saying the entity changed — unless the full body
                        // is the probed size and Last-Modified: then only this node's ETag differs. Retry ranged
                        // without If-Range; the 206 is still held to size and Last-Modified below.
                        if ifRange != nil, http.statusCode == 200 {
                            if Self.sameEntityDespiteETag(plan: plan, contentLength: http.expectedContentLength,
                                                          lastModified: http.value(forHTTPHeaderField: "Last-Modified")) {
                                ifRangeDistrusted = true
                                continue
                            }
                            if attempt >= settings.maxAttempts { throw DownloadError.remoteFileChanged }
                            try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                            continue
                        }
                        if isMirror, attempt < settings.maxAttempts {
                            await pool.demote(url)
                            continue
                        }
                        throw DownloadError.httpStatus(http.statusCode)
                    case .accept:
                        break
                    }
                    // Every 206 must describe the same total size — a wrong object must not merge in.
                    // Same-size edits slip past that, so the primary's 206 must also carry the probed ETag.
                    let sizeChanged = plan.totalBytes.map { expected in
                        Self.contentRangeTotal(http).map { $0 != expected } ?? false
                    } ?? false
                    let entityChanged = !isMirror && Self.entityDiffers(
                        plan: plan, servedETag: http.value(forHTTPHeaderField: "ETag"),
                        servedLastModified: http.value(forHTTPHeaderField: "Last-Modified"))
                    if sizeChanged || entityChanged {
                        streamer.cancelTask()
                        if isMirror { await pool.demote(url) }
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.remoteFileChanged }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    }
                    // A 206 that starts elsewhere would land at the wrong offset; one that overshoots is clamped below.
                    guard let served = Self.contentRange(http)
                            ?? Self.impliedRange(http, start: segStart, end: end),
                          served.start == segStart else {
                        streamer.cancelTask()
                        if isMirror { await pool.demote(url) }
                        await governor.release()
                        if attempt >= settings.maxAttempts {
                            throw DownloadError.network("Server returned the wrong byte range for segment \(index)")
                        }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    }
                    let limit = min(served.end, end) - segStart + 1

                    do {
                        try handle.seek(toOffset: UInt64(segStart))
                        try await pumpBody(bytes, into: handle, streamer: streamer, ledger: ledger,
                                           segment: index, limiter: limiter, flushSize: flushSize,
                                           written: &written, limit: limit)
                    } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
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
                    // A clean `pumpBody` return does NOT prove the whole range arrived — check for a gap.
                    if start + written > end { break }
                    if attempt >= settings.maxAttempts {
                        throw DownloadError.network(
                            "Incomplete segment \(index): got \(written) of \(end - start + 1) bytes")
                    }
                    try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                }
            } onCancel: {
                streamerBox.cancel()
            }
            // Explicit close: a flush failure must fail the task, not report `.completed` half-flushed.
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

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
        var progressMark: Int64 = 0
        var ifRangeDistrusted = false
        do {
            try await withTaskCancellationHandler {
                while start + written <= end {
                    try Task.checkCancellation()
                    if written > progressMark { progressMark = written; attempt = 0 }
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
                    // Global THEN adapter, always: a cancellation here must hand the global slot back.
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
                        expectedTotal: plan.totalBytes,
                        ifRange: (isMirror || ifRangeDistrusted) ? nil : Self.strongETag(plan.etag)
                    )

                    // curl's write callback can't await; `onBytes` fires post-write, so tally == on disk.
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
                    // Drain before ANY branching, so retry offsets read a fully-credited ledger.
                    let trailing = tally.drain()
                    if trailing > 0 { await ledger.advance(segment: index, by: trailing) }

                    // A local disk failure says nothing about the NIC: fail now, never demote or retry.
                    if let failure = response.writeFailure {
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        throw failure
                    }
                    // A policy refusal, not a flaky link: retrying just asks the same server again.
                    if response.redirectRefused {
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        throw Self.redirectRefusal
                    }

                    if response.rangeMismatch {
                        if isMirror { await pool.demote(url) }
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        if attempt >= settings.maxAttempts {
                            throw DownloadError.network("Server returned the wrong byte range for segment \(index)")
                        }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    }

                    if response.aborted && !response.rangeTotalMismatch {
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        throw CancellationError()
                    }

                    // CurlBridge aborted before writing a body: credit neither ledger nor `written`.
                    if response.rangeTotalMismatch {
                        if isMirror { await pool.demote(url) }
                        await adapters.demote(adapter)
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        if attempt >= settings.maxAttempts { throw DownloadError.remoteFileChanged }
                        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                        continue
                    }

                    // Must precede the curl-error branch: the ranged-200 abort surfaces as CURLE_WRITE_ERROR.
                    if response.rangeIgnored {
                        if isMirror { await pool.demote(url) }
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        // With If-Range, a 200 is the server saying the entity changed — unless the full
                        // body is the probed size and Last-Modified (a node with its own ETag).
                        if boundReq.ifRange != nil,
                           Self.sameEntityDespiteETag(plan: plan, contentLength: response.contentLength,
                                                      lastModified: response.lastModified) {
                            ifRangeDistrusted = true
                            continue
                        }
                        let changed = boundReq.ifRange != nil
                        if (upgraded || isMirror || changed), attempt < settings.maxAttempts {
                            try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                            continue
                        }
                        throw changed ? DownloadError.remoteFileChanged : DownloadError.httpStatus(200)
                    }

                    // The tally pump already credited the ledger; only the resume offset commits here.
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
                        // Per-IP pushback shrinks only this adapter, or one throttled source starves all.
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
                        // `rangeIgnored` is set from the write thunk, so an EMPTY ranged 200 lands here.
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

                    // Multi-path requires a matching Content-Range total (Swift-side belt); a 206 with no
                    // Content-Range at all was already held to our one requested span by CurlBridge.
                    if let expected = plan.totalBytes, response.hasContentRange {
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
                    // Weak ETags get no If-Range, so a same-size swap is only visible here — after the write.
                    if !isMirror, Self.entityDiffers(plan: plan, servedETag: response.etag,
                                                     servedLastModified: response.lastModified) {
                        await adapterGovernors.release(adapter.bsdName)
                        await governor.release()
                        throw DownloadError.remoteFileChanged
                    }

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

    private func runSingle() async throws -> TransferOutcome {
        // `Data().write` creates AND truncates; `createFile` no-ops, leaving stale trailing bytes.
        try Data().write(to: plan.destination)

        let ledger = Ledger(continuation: continuation, meta: nil,
                            initialSegmentBytes: [0: 0], connectionCount: 1,
                            expectedTotal: plan.totalBytes)
        let limiter = Self.makeLimiter(plan)

        let upgrade = spawnUpgradeProber()
        defer { upgrade?.task.cancel() }
        do {
            try await streamSingle(session: plan.session, limiter: limiter, ledger: ledger,
                                   url: plan.url, fileURL: plan.destination,
                                   upgrade: upgrade?.signal)
        } catch let interrupt as UpgradeInterrupt {
            guard let upgrade else { throw interrupt }
            let written = await ledger.totalBytes()    // == flushed == on-disk bytes
            return try await upgradeToSegmented(total: upgrade.total, written: written)
        }

        let bytesWritten = await ledger.totalBytes()
        // A close-delimited stream can end cleanly while short — reporting that is silent truncation.
        if let total = plan.totalBytes, bytesWritten != total {
            throw DownloadError.network("Incomplete download: wrote \(bytesWritten) of \(total) bytes")
        }
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: nil, usedSegments: 1)
    }

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
        defer { upgrade?.task.cancel() }
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
                expectedTotal: nil
            )

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

            if let failure = response.writeFailure {
                try? handle.close()
                throw failure
            }
            if response.redirectRefused {
                try? handle.close()
                throw Self.redirectRefusal
            }

            if response.aborted {
                // Signal-abort means upgrade; if it raced task cancellation, cancellation wins.
                if let upgrade, upgrade.signal.isTripped, !Task.isCancelled {
                    try handle.close()                       // flush failure = real failure
                    let written = await ledger.totalBytes()
                    switch Self.classify(response.httpStatus, ranged: false) {
                    case .accept:
                        // Probe and stream can see different ETags: a mismatch drops the prefix, not the run.
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
                        // The unranged GET is 429/5xx'd while ranges probed 206: upgrading IS the retry.
                        return try await upgradeToSegmented(total: upgrade.total, written: written)
                    case .reject:
                        if response.httpStatus == 0 {
                            return try await upgradeToSegmented(total: upgrade.total, written: written)
                        }
                        throw DownloadError.httpStatus(response.httpStatus)
                    }
                }
                try? handle.close()
                throw CancellationError()
            }
            // Any bytes written rule out a retry: restarting an unranged stream appends a second copy.
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

    private func streamSingle(session: URLSession, limiter: RateLimiter?, ledger: Ledger,
                              url: URL, fileURL: URL, upgrade: UpgradeSignal?) async throws {
        let settings = plan.settings
        let flushSize = plan.flushSize
        let streamerBox = StreamerBox()
        try await withTaskCancellationHandler {
            // Retry only connect/status: no-range can't resume, so the body read stays outside this loop.
            var result: (HTTPURLResponse, AsyncThrowingStream<Data, Error>, ChunkStreamer)?
            var attempt = 0
            while true {
                try Task.checkCancellation()
                if let upgrade, upgrade.isTripped { throw UpgradeInterrupt() }
                attempt += 1
                let req = Self.makeRequest(url, settings: settings)
                do {
                    let opened = try await Self.openStream(
                        session: session, request: req,
                        register: { streamerBox.set($0); if Task.isCancelled { streamerBox.cancel() } })
                    let decision = Self.classify(opened.0.statusCode, ranged: false)
                    if decision == .retry, attempt < settings.maxAttempts {
                        opened.2.cancelTask()
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
            guard let (http, bytes, streamer) = result else { return }

            // The streamed 200 must be the probed entity, or prefix and ranged tail are different files.
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
                var written: Int64 = 0
                try await pumpBody(bytes, into: handle, streamer: streamer, ledger: ledger,
                                   segment: 0, limiter: limiter, flushSize: flushSize, written: &written,
                                   upgrade: pumpUpgrade)
                try handle.close()
            } catch let interrupt as UpgradeInterrupt {
                // The only error path that KEEPS its bytes, so a close(2) failure must fail the task.
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

    private func pumpBody(_ bytes: AsyncThrowingStream<Data, Error>, into handle: FileHandle,
                          streamer: ChunkStreamer, ledger: Ledger, segment: Int,
                          limiter: RateLimiter?, flushSize: Int, written: inout Int64,
                          limit: Int64? = nil, upgrade: UpgradeSignal? = nil) async throws {
        // `consumed` must be called per chunk: it releases the backpressure credit that resumes the task.
        var buffer = Data()
        buffer.reserveCapacity(flushSize)
        var accepted: Int64 = 0
        for try await chunk in bytes {
            streamer.consumed(chunk.count)
            var piece = chunk
            // `limit` is the byte count the 206 was asked for: an overshoot must not spill into the next segment.
            var overshoot = false
            if let limit, Int64(piece.count) > limit - accepted {
                piece = piece.prefix(Int(max(0, limit - accepted)))
                overshoot = true
            }
            accepted += Int64(piece.count)
            if buffer.isEmpty && piece.count >= flushSize {
                // A chunk already the size of a flush skips the accumulator copy.
                try await flush(piece, into: handle, ledger: ledger, segment: segment, limiter: limiter)
                written += Int64(piece.count)
            } else {
                buffer.append(piece)
                if buffer.count >= flushSize {
                    try await flush(buffer, into: handle, ledger: ledger, segment: segment, limiter: limiter)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if overshoot { streamer.cancelTask(); break }
            // Stop only on a flush boundary: `written` must equal the bytes on disk (the prefix).
            if buffer.isEmpty, let upgrade, upgrade.isTripped { throw UpgradeInterrupt() }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty {
            try await flush(buffer, into: handle, ledger: ledger, segment: segment, limiter: limiter)
            written += Int64(buffer.count)
        }
    }

    private func flush(_ data: Data, into handle: FileHandle, ledger: Ledger, segment: Int,
                       limiter: RateLimiter?) async throws {
        guard !data.isEmpty else { return }
        try Task.checkCancellation()
        try handle.write(contentsOf: data)
        await ledger.advance(segment: segment, by: data.count)
        // The flag read is lock-only: an unlimited chain costs no actor hop per flush.
        if let limiter, !limiter.isEffectivelyUnlimited { await limiter.pace(data.count) }
    }

    static func clampSegmentCount(_ requested: Int, total: Int64,
                                  minSegment: Int64 = 64 * 1024) -> Int {
        // Not `(total + minSegment - 1) / …`: that overflows and traps near `Int64.max`.
        let bySize = total <= 0 ? 1 : Int(min(Int64(Int.max), (total - 1) / minSegment + 1))
        return max(1, min(requested, bySize))
    }

    static func makeRanges(total: Int64, count: Int) -> [Range64] {
        guard total > 0 else { return [] }
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

    /// Below this size a mid-flight re-segmentation costs more than it saves.
    static let upgradeMinBytes: Int64 = 8 * 1024 * 1024
    /// Must mirror ``AggregationPolicy/multiPathSegmentCount``'s hard cap.
    static let upgradeMaxConnections = 32

    /// A cooperative-stop sentinel, never a failure.
    private struct UpgradeInterrupt: Error {}

    /// Without a validator the prefix can't be proven identical to later ranged bytes — never upgrade.
    static func shouldAttemptUpgrade(totalBytes: Int64?, acceptsRanges: Bool,
                                     etag: String?, lastModified: String?) -> Bool {
        guard let total = totalBytes, total >= upgradeMinBytes, !acceptsRanges else { return false }
        return etag != nil || lastModified != nil
    }

    static func upgradedLayout(total: Int64, written: Int64, connections: Int,
                               minSegment: Int64 = 64 * 1024) -> (ranges: [Range64], restored: [Int: Int64]) {
        let remainder = max(0, total - written)
        let count = clampSegmentCount(max(1, connections), total: remainder, minSegment: minSegment)
        let tail = makeRanges(total: remainder, count: count)
            .map { Range64(start: $0.start + written, end: $0.end + written) }
        guard written > 0 else { return (tail, [:]) }
        return ([Range64(start: 0, end: written - 1)] + tail, [0: written])
    }

    /// The caller owns `defer { upgrade?.task.cancel() }`.
    private func spawnUpgradeProber() -> (task: Task<Void, Never>, signal: UpgradeSignal, total: Int64)? {
        guard plan.requestExtraConnections != nil,
              Self.shouldAttemptUpgrade(totalBytes: plan.totalBytes,
                                        acceptsRanges: plan.acceptsRanges,
                                        etag: plan.etag, lastModified: plan.lastModified),
              let total = plan.totalBytes else { return nil }
        let signal = UpgradeSignal()
        let probing = plan.upgradeProbing
        // Captures value state only: capturing `self` here would make a retain cycle.
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

    /// MUST use openStream + cancelTask: a server ignoring Range answers 200 with the WHOLE body.
    static func probeMidpointRange(plan: TransferPlan, total: Int64) async -> Bool {
        let box = StreamerBox()
        return await withTaskCancellationHandler {
            var req = makeRequest(plan.url, settings: plan.settings)
            let m = max(0, total / 2)
            req.setValue("bytes=\(m)-\(m)", forHTTPHeaderField: "Range")
            guard let (http, _, streamer) = try? await openStream(
                session: plan.session, request: req,
                // Re-check synchronously BEFORE resume, or a cancelled prober leaves a stray GET.
                register: { box.set($0); if Task.isCancelled { box.cancel() } }
            ) else { return false }
            streamer.cancelTask()          // headers only — never drain the body
            guard http.statusCode == 206, contentRangeTotal(http) == total else { return false }
            return validatorsAllowResume(
                cursorETag: plan.etag, cursorLastModified: plan.lastModified,
                probeETag: http.value(forHTTPHeaderField: "ETag"),
                probeLastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        } onCancel: { box.cancel() }
    }

    /// Must extend the W-byte file via `preallocate`; the singles' `Data().write` would erase the prefix.
    private func upgradeToSegmented(total: Int64, written: Int64) async throws -> TransferOutcome {
        if written == total {
            return TransferOutcome(bytesWritten: written, resumeData: nil, usedSegments: 1)
        }
        // A streamed 200 can be LONGER than the probed size; an overshoot must never reach preallocate.
        guard written < total else {
            throw DownloadError.network("Incomplete download: wrote \(written) of \(total) bytes")
        }
        try Task.checkCancellation()
        let multiPath = plan.boundAdapters.count >= 2
        let minSegment: Int64 = multiPath ? 32 * 1024 : 64 * 1024
        // The transfer already holds 1 reserved connection, so it asks for `sizeCap - 1` extras.
        let sizeCap = Self.clampSegmentCount(Self.upgradeMaxConnections,
                                             total: total - written, minSegment: minSegment)
        let granted = await plan.requestExtraConnections?(max(0, sizeCap - 1)) ?? 0
        // Fan-out is 1 + granted, never the adapter count: more segments than charged falsifies accounting.
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

    /// ALL outbound requests go through here: a missing UA makes some CDNs reset, surfacing as -1005.
    static func makeRequest(_ url: URL, settings: RequestSettings) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(settings.userAgent, forHTTPHeaderField: "User-Agent")
        // Identity, or transparent gzip makes Content-Length disagree with the bytes we
        // write — see the same header in HTTPEngine.makeRequest. Ranged segments double
        // down on it: offsets into a compressed stream do not address payload bytes.
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in settings.extraHeaders where isSafeHeader(name: name, value: value) {
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

    /// Secrets resolved for the PRIMARY host must never ride to a mirror on another host.
    private func request(for url: URL) -> URLRequest {
        var settings = plan.settings
        if url.host?.lowercased() != plan.url.host?.lowercased() {
            settings.authorization = nil
            settings.referer = nil
            settings.extraHeaders = [:]
        }
        return Self.makeRequest(url, settings: settings)
    }

    /// `register` runs before the task starts, which is what makes cancellation work.
    static func openStream(
        session: URLSession, request: URLRequest,
        register: (ChunkStreamer) -> Void
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, ChunkStreamer) {
        let streamer = ChunkStreamer()
        var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        let body = AsyncThrowingStream<Data, Error> { bodyContinuation = $0 }
        #if os(Linux)
        // corelibs ignores per-task delegates, and freeing its session can abort: keep one shared session.
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

    static func contentRangeTotal(_ http: HTTPURLResponse) -> Int64? {
        http.value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last.flatMap { Int64($0) }
    }

    static let redirectRefusal = DownloadError.network(
        "The server redirected to an internal network address, which Goel° refuses to follow")

    static func isRetryableStatus(_ status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    enum StatusClass: Equatable { case accept, retry, reject }

    static func transportError(_ curlCode: Int, via adapter: BoundAdapter?) -> String {
        let message = String(cString: gcb_error_message(Int32(curlCode)))
        guard let adapter else { return message }
        return "\(message) (via \(adapter.label))"
    }

    /// A ranged pump accepts ONLY 206 — a full 200 body would corrupt every offset.
    static func classify(_ status: Int, ranged: Bool) -> StatusClass {
        if isRetryableStatus(status) { return .retry }
        let accepted = ranged ? (status == 206) : (200..<300).contains(status)
        return accepted ? .accept : .reject
    }

    /// Deliberately excludes `.cancelled` — that is our own pause/remove, never a retry.
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

    /// The jitter de-synchronises a rate-limited herd; `Task.sleep` throws so pause/remove interrupt.
    private func backoff(attempt: Int, response: HTTPURLResponse?, retryInterval: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(
            Self.backoffSeconds(attempt: attempt, retryInterval: retryInterval,
                                retryAfter: response?.value(forHTTPHeaderField: "Retry-After"))
            * 1_000_000_000))
    }

    /// Proportional jitter (±50%): a fixed +0–0.4 s left sixteen segments retrying in lockstep at the 6 s cap.
    static func backoffSeconds(attempt: Int, retryInterval: Double, retryAfter: String?) -> Double {
        var seconds = min(6.0, pow(2.0, Double(max(1, attempt) - 1)) * 0.4)
        if retryInterval > 0 { seconds = max(seconds, retryInterval) }
        seconds = Double.random(in: (seconds * 0.5)...(seconds * 1.5))
        // The server's own advice is a floor, never jittered below.
        if let header = retryAfter, let advised = Double(header.trimmingCharacters(in: .whitespaces)) {
            seconds = min(15.0, max(seconds, advised))
        }
        return seconds
    }

    static func preallocate(_ url: URL, size: Int64) throws {
        // The size is a parsed server header: negative would trap `UInt64(size)` below.
        guard size >= 0 else {
            throw DownloadError.network("Server declared an impossible size (\(size) bytes)")
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Reserve BEFORE extending: F_PREALLOCATE grows from the physical end, and once `truncate` has moved
        // the logical EOF out those blocks would sit past it instead of backing the file's own range.
        try reserveBlocks(handle.fileDescriptor, size: size, url: url)
        try handle.truncate(atOffset: UInt64(size))
    }

    /// `truncate` is sparse on APFS and reserves nothing, so N downloads all pass a free-space preflight.
    /// Covers [0, size) for a file still shorter than `size`; a resumed file already at full length keeps
    /// whatever holes it has (best-effort — its preflight counted only the missing bytes anyway).
    static func reserveBlocks(_ fd: Int32, size: Int64, url: URL) throws {
        #if canImport(Darwin)
        var st = stat()
        guard fstat(fd, &st) == 0, Int64(st.st_size) < size else { return }
        let allocated = Int64(st.st_blocks) * 512
        guard size > allocated else { return }
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL),
                             fst_posmode: F_PEOFPOSMODE, fst_offset: 0,
                             fst_length: off_t(size - allocated), fst_bytesalloc: 0)
        if fcntl(fd, F_PREALLOCATE, &store) == 0 { return }
        store.fst_flags = UInt32(F_ALLOCATEALL)
        if fcntl(fd, F_PREALLOCATE, &store) == 0 { return }
        // Only a genuine lack of space fails the start; filesystems without F_PREALLOCATE stay sparse.
        if errno == ENOSPC || errno == EDQUOT {
            throw diskFull(at: url, needed: size - allocated)
        }
        #endif
    }

    /// ENOSPC / EDQUOT anywhere in the chain, as Foundation or POSIX reports it; nil for any other failure.
    static func diskFullError(_ error: Error) -> DownloadError? {
        if let de = error as? DownloadError {
            if case .diskFull = de { return de }
            return nil
        }
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT) {
                return .diskFull(needed: 0, available: 0)
            }
            if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                return .diskFull(needed: 0, available: 0)
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// Best-effort figures for the message; a volume that can't be queried reports 0 available.
    static func diskFull(at url: URL, needed: Int64) -> DownloadError {
        let directory = url.deletingLastPathComponent().path
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory)
        let available = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return .diskFull(needed: max(0, needed), available: max(0, available))
    }

    /// Only a strong validator may ride If-Range (RFC 9110 §13.1.5); a weak one would make every 206 a 200.
    static func strongETag(_ etag: String?) -> String? {
        guard let etag, !etag.isEmpty, !etag.hasPrefix("W/") else { return nil }
        return etag
    }

    /// Unknown on either side proves nothing, so it passes; weakness is ignored because CDNs flip it per edge.
    static func sameEntity(probed: String?, served: String?) -> Bool {
        guard let probed, let served else { return true }
        func opaque(_ tag: String) -> Substring {
            tag.hasPrefix("W/") ? tag.dropFirst(2) : Substring(tag)
        }
        return opaque(probed) == opaque(served)
    }

    /// Load-balanced origins tag identical bytes differently per node, so an ETag mismatch alone is not
    /// proof. A matching Last-Modified on both sides vouches for the entity (size is checked separately);
    /// with no Last-Modified to compare, the ETag is the only evidence and a mismatch stays a change.
    static func entityDiffers(plan: TransferPlan, servedETag: String?, servedLastModified: String?) -> Bool {
        guard !sameEntity(probed: plan.etag, served: servedETag) else { return false }
        if let probed = plan.lastModified, let served = servedLastModified, probed == served { return false }
        return true
    }

    /// An If-Range 200 whose full body is the probed size and Last-Modified is the same file from a node
    /// with its own ETag — not a changed entity.
    static func sameEntityDespiteETag(plan: TransferPlan, contentLength: Int64?,
                                      lastModified: String?) -> Bool {
        guard let total = plan.totalBytes, let contentLength, contentLength == total,
              let probed = plan.lastModified, let lastModified else { return false }
        return probed == lastModified
    }

    /// RFC 9110 requires Content-Range on a single-range 206, but some servers omit it. We asked for ONE
    /// range, so the body is taken as that range: an overshoot is clamped and a short body retried by the
    /// caller. A declared length that isn't the span, or a multipart body, is refused.
    static func impliedRange(_ http: HTTPURLResponse, start: Int64, end: Int64) -> (start: Int64, end: Int64)? {
        guard http.statusCode == 206, http.value(forHTTPHeaderField: "Content-Range") == nil,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("multipart/") != true
        else { return nil }
        let length = http.expectedContentLength
        guard length < 0 || length == end - start + 1 else { return nil }
        return (start, end)
    }

    /// `Content-Range: bytes a-b/total` → (a, b); nil when absent, unsatisfied (`*`) or unparseable.
    static func contentRange(_ http: HTTPURLResponse) -> (start: Int64, end: Int64)? {
        guard let raw = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        return contentRange(parsing: raw)
    }

    static func contentRange(parsing raw: String) -> (start: Int64, end: Int64)? {
        var spec = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard spec.lowercased().hasPrefix("bytes") else { return nil }
        spec = spec.dropFirst(5).drop { $0 == " " || $0 == "=" }
        guard let span = spec.split(separator: "/").first else { return nil }
        let bounds = span.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let a = Int64(bounds[0]), let b = Int64(bounds[1]),
              a >= 0, b >= a else { return nil }
        return (a, b)
    }

    /// CR/LF/NUL in a name or value would split the request line into a smuggled header.
    static func isSafeHeader(name: String, value: String) -> Bool {
        // Scalars, not Characters: "\r\n" is ONE grapheme and slips past a Character check.
        let forbidden: (Unicode.Scalar) -> Bool = { $0 == "\r" || $0 == "\n" || $0 == "\0" }
        guard !name.isEmpty, !name.contains(":") else { return false }
        return !name.unicodeScalars.contains(where: forbidden) && !value.unicodeScalars.contains(where: forbidden)
    }

    /// With no validator on either side nothing proves the remote is unchanged, so never resume.
    static func validatorsAllowResume(
        cursorETag: String?, cursorLastModified: String?,
        probeETag: String?, probeLastModified: String?
    ) -> Bool {
        if let a = cursorETag, let b = probeETag { return a == b }
        if let a = cursorLastModified, let b = probeLastModified { return a == b }
        return false
    }

    /// ``preallocate`` silently recreates a deleted partial, so a mostly-zero file would pass as done.
    static func destinationHoldsPreallocation(_ url: URL, total: Int64) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.int64Value else { return false }
        return size == total
    }

    /// A corrupt cursor must force a fresh start, never an out-of-bounds seek (negatives trap `UInt64`).
    static func cursorIsWellFormed(_ cursor: ResumeCursor, total: Int64) -> Bool {
        guard cursor.completed.count == cursor.ranges.count else { return false }
        for (i, r) in cursor.ranges.enumerated() {
            guard r.start >= 0, r.end >= r.start, r.end < total else { return false }
            let done = cursor.completed[i]
            guard done >= 0, done <= r.end - r.start + 1 else { return false }
        }
        // Ranges must tile [0, total) exactly: overlaps or gaps would pass a sum check with zero-filled holes.
        let sorted = cursor.ranges.sorted { $0.start < $1.start }
        guard let first = sorted.first, let last = sorted.last else { return total == 0 }
        guard first.start == 0, last.end == total - 1 else { return false }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.end + 1 != b.start { return false }
        return true
    }

    struct Range64: Codable, Sendable {
        var start: Int64
        var end: Int64
    }

    struct CursorMeta: Sendable {
        var etag: String?
        var lastModified: String?
        var total: Int64
        var ranges: [Range64]
    }

    struct ResumeCursor: Codable, Sendable {
        var etag: String?
        var lastModified: String?
        var totalBytes: Int64
        var ranges: [Range64]
        var completed: [Int64]
    }

    /// If every URL is demoted the slate is wiped — the pool must never go empty.
    actor MirrorPool {
        private let urls: [URL]
        private var demoted: Set<URL> = []

        init(primary: URL, mirrors: [URL]) {
            self.urls = [primary] + mirrors.filter { $0 != primary }
        }

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

    private actor Ledger {
        private let continuation: AsyncStream<TransferProgress>.Continuation
        private let meta: CursorMeta?
        private let expectedTotal: Int64?
        private var segmentBytes: [Int: Int64]
        private var runningTotal: Int64 = 0
        private let connectionCount: Int
        private var segmentAdapters: [Int: (id: String, label: String)] = [:]
        private var lastEmit = Date.distantPast
        private var lastEmitBytes: Int64 = 0
        private var lastResumeEmit = Date.distantPast
        private var lastConnectionsEmit = Date.distantPast
        private var lastConnectionsBytes: [Int: Int64] = [:]
        private let durability: DurabilityBarrier?
        /// Range labels never change, so they're formatted once rather than per segment per second.
        private let rangeLabels: [String]

        /// Each cursor costs a durability barrier, so it's published at this cadence, not per tick.
        static let resumeCadence: TimeInterval = 5.0

        init(continuation: AsyncStream<TransferProgress>.Continuation, meta: CursorMeta?,
             initialSegmentBytes: [Int: Int64], connectionCount: Int, expectedTotal: Int64?,
             durability: DurabilityBarrier? = nil) {
            self.continuation = continuation
            self.meta = meta
            self.segmentBytes = initialSegmentBytes
            self.runningTotal = initialSegmentBytes.values.reduce(0, +)
            self.connectionCount = connectionCount
            self.expectedTotal = expectedTotal
            self.durability = durability
            self.rangeLabels = meta?.ranges.map {
                "\(Self.byteLabel($0.start)) – \(Self.byteLabel($0.end + 1))"
            } ?? []
        }

        func setAdapter(segment: Int, id: String, label: String) {
            segmentAdapters[segment] = (id, label)
        }

        func totalBytes() -> Int64 { runningTotal }

        func advance(segment: Int, by n: Int) {
            segmentBytes[segment, default: 0] += Int64(n)
            runningTotal += Int64(n)
            let total = runningTotal

            let now = Date()
            guard now.timeIntervalSince(lastEmit) > 0.1 else { return }
            let dt = now.timeIntervalSince(lastEmit)
            let speed = (dt > 0 && dt < 3600) ? Double(total - lastEmitBytes) / dt : 0
            lastEmit = now
            lastEmitBytes = total

            continuation.yield(TransferProgress(
                bytesDownloaded: total, downloadSpeed: speed,
                connectionCount: connectionCount, resumeData: maybeResume(now: now),
                connections: maybeConnections(now: now, overallSpeed: speed)))
        }

        private func maybeConnections(now: Date, overallSpeed: Double) -> [TaskConnection]? {
            let dt = now.timeIntervalSince(lastConnectionsEmit)
            guard dt >= 1.0 else { return nil }
            defer {
                lastConnectionsEmit = now
                lastConnectionsBytes = segmentBytes
            }
            guard let meta else {
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
                    detail: rangeLabels[i],
                    downloadSpeed: max(0, speed),
                    progress: length > 0 ? min(1, Double(done) / Double(length)) : 0,
                    adapterId: adapter?.id,
                    adapterLabel: adapter?.label)
            }
        }

        private static func byteLabel(_ n: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
        }

        private func maybeResume(now: Date) -> Data? {
            guard let meta else { return nil }
            if now.timeIntervalSince(lastResumeEmit) < Self.resumeCadence { return nil }
            lastResumeEmit = now
            // Bytes are credited after write(2) returns, so a barrier HERE covers every byte this cursor claims.
            // Without it the cursor can reach SQLite before the data, and a power cut leaves zero-filled "done" ranges.
            return durableResumeData(meta)
        }

        /// The cursor as of the last write, barrier'd, flagged so the engine takes only the cursor from it.
        /// Called once every writer has stopped (pause, remove, failure), so it covers every flushed byte.
        func publishFinalCursor() {
            guard let meta, let data = durableResumeData(meta) else { return }
            continuation.yield(TransferProgress(
                bytesDownloaded: runningTotal, downloadSpeed: 0, connectionCount: 0,
                resumeData: data, connections: nil, isFinalCursor: true))
        }

        /// nil when the barrier fails: publishing then would let the cursor claim bytes not yet on disk.
        private func durableResumeData(_ meta: CursorMeta) -> Data? {
            if let durability, !durability.sync() {
                GoelLog.engineHTTP.notice("Durability barrier failed; resume cursor withheld",
                                          .detail(String(cString: strerror(errno))))
                return nil
            }
            return Self.buildResumeData(meta: meta, segmentBytes: segmentBytes)
        }

        func currentResumeData() -> Data? {
            guard let meta else { return nil }
            return Self.buildResumeData(meta: meta, segmentBytes: segmentBytes)
        }

        private static func buildResumeData(meta: CursorMeta, segmentBytes: [Int: Int64]) -> Data? {
            let completed = meta.ranges.indices.map { segmentBytes[$0] ?? 0 }
            let cursor = ResumeCursor(
                etag: meta.etag, lastModified: meta.lastModified,
                totalBytes: meta.total, ranges: meta.ranges, completed: completed)
            do {
                return try JSONEncoder().encode(cursor)
            } catch {
                GoelLog.engineHTTP.error("Couldn't encode the resume cursor",
                                         .detail(String(describing: error)))
                return nil
            }
        }
    }
}

struct TransferPlan: Sendable {
    var url: URL
    var destination: URL
    var totalBytes: Int64?
    var acceptsRanges: Bool
    var etag: String?
    var lastModified: String?
    var existingResume: Data?
    var segmentCount: Int
    var session: URLSession
    var settings: RequestSettings
    /// This download's OWN limit (0 = uncapped); the profile ceiling rides ``sharedLimiter``.
    var maxBytesPerSecond: Int64
    var sharedLimiter: RateLimiter? = nil
    var flushSize: Int
    /// Segmented only: a 206's Content-Range proves a mirror serves the same file, single-stream can't.
    var mirrors: [URL] = []
    var boundAdapters: [BoundAdapter] = []
    /// Connect timeout forwarded to bound HTTP (seconds).
    var connectTimeout: Double = 30
    var upgradeProbing = UpgradeProbing()
    /// Returns granted (0...wanted); nil disables the mid-flight upgrade entirely.
    var requestExtraConnections: (@Sendable (Int) async -> Int)? = nil
}

struct UpgradeProbing: Sendable {
    var initialDelay: TimeInterval = 10
    var interval: TimeInterval = 30
    var maxAttempts: Int = 5
}

struct RequestSettings: Sendable {
    var userAgent: String
    var maxAttempts: Int
    var retryInterval: Double
    var authorization: String?
    /// Same-origin only — must be stripped on a cross-host mirror request.
    var referer: String?
    /// Same-origin only — must be stripped on a cross-host mirror request.
    var extraHeaders: [String: String] = [:]
}

struct TransferOutcome: Sendable {
    var bytesWritten: Int64
    var resumeData: Data?
    var usedSegments: Int
}

struct TransferProgress: Sendable {
    var bytesDownloaded: Int64
    var downloadSpeed: Double
    var connectionCount: Int
    var resumeData: Data?
    var connections: [TaskConnection]?
    /// The unwind's last word: carries only the cursor, never a live speed/progress tick.
    var isFinalCursor: Bool = false
}

#if os(Linux)
/// corelibs ignores `URLSessionTask.delegate`, and freeing a per-stream session can abort.
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
    /// Lets a continuation arriving after completion resume with the real cause instead of hanging.
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

    /// If the task ALREADY completed, resume here: `didCompleteWithError` never fires again.
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

    /// Releases backpressure credit as the consumer pulls, which may resume a suspended task.
    func consumed(_ n: Int) {
        lock.lock()
        outstanding -= n
        let resume = suspended && !done && outstanding <= lowWater
        if resume { suspended = false }
        let t = task
        lock.unlock()
        if resume { t?.resume() }
    }

    func cancelTask() {
        lock.lock(); let t = task; lock.unlock()
        t?.cancel()
    }

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
        // `suspend()` MUST happen under the lock that publishes `suspended`, or the wakeup is lost.
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
        // Redirects must strip per-task secrets and refuse loopback/link-local — else SSRF.
        // The spelling screen alone passes a public name that resolves internally
        // (`127.0.0.1.nip.io`), so the hop's name is resolved before it is followed.
        let original = task.originalRequest?.url
        guard let next = RedirectSanitizer.followed(request, originalURL: original),
              let url = next.url else {
            completionHandler(nil)
            return
        }
        RedirectSanitizer.resolveThenFollow(next, url: url, originalURL: original,
                                            completionHandler: completionHandler)
    }
}

final class StreamerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ChunkStreamer?
    func set(_ streamer: ChunkStreamer) { lock.lock(); current = streamer; lock.unlock() }
    func cancel() { lock.lock(); let s = current; lock.unlock(); s?.cancelTask() }
}

/// One descriptor on the destination: fsync is per inode, so it flushes what every segment handle wrote.
final class DurabilityBarrier: @unchecked Sendable {
    private let handle: FileHandle

    init(_ url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
    }

    /// F_BARRIERFSYNC orders data before the later SQLite write without F_FULLFSYNC's full cache flush.
    func sync() -> Bool {
        let fd = handle.fileDescriptor
        #if canImport(Darwin)
        if fcntl(fd, F_BARRIERFSYNC) == 0 { return true }
        return fsync(fd) == 0
        #else
        return fdatasync(fd) == 0
        #endif
    }

    func close() { try? handle.close() }
}

/// A lock, not an actor: the pump reads this at every flush and must not hop executors.
final class UpgradeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() { lock.lock(); tripped = true; lock.unlock() }
    var isTripped: Bool { lock.lock(); defer { lock.unlock() }; return tripped }
}
