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

        if let data = plan.existingResume,
           let cursor = try? JSONDecoder().decode(ResumeCursor.self, from: data),
           cursor.totalBytes == total,
           Self.cursorIsWellFormed(cursor, total: total),
           Self.validatorsAllowResume(
                cursorETag: cursor.etag, cursorLastModified: cursor.lastModified,
                probeETag: plan.etag, probeLastModified: plan.lastModified),
           // Multi-path needs ≥1 range per adapter, else a stale cursor pins everything to one NIC.
           !(multiPath && cursor.ranges.count < plan.boundAdapters.count
             && cursor.completed.allSatisfy { $0 == 0 }),
           Self.destinationHoldsPreallocation(plan.destination, total: total) {
            self.segmented = true
            self.plannedRanges = cursor.ranges
            self.restoredBytes = Dictionary(
                uniqueKeysWithValues: cursor.completed.enumerated().map { ($0.offset, $0.element) })
        } else {
            self.segmented = true
            let count = multiPath
                ? Self.clampSegmentCount(wanted, total: total, minSegment: 32 * 1024)
                : Self.clampSegmentCount(wanted, total: total)
            self.plannedRanges = Self.makeRanges(total: total, count: count)
            self.restoredBytes = [:]
        }
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
        let ledger = Ledger(continuation: continuation, meta: meta,
                            initialSegmentBytes: initialBytes, connectionCount: ranges.count,
                            expectedTotal: total)

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

        let bytesWritten = await ledger.totalBytes()
        // Assert the whole file is accounted for, so a silent gap can't be emitted as `.completed`.
        guard bytesWritten == total else {
            throw DownloadError.network("Incomplete download: wrote \(bytesWritten) of \(total) bytes")
        }
        let resumeData = await ledger.currentResumeData()
        return TransferOutcome(bytesWritten: bytesWritten, resumeData: resumeData, usedSegments: ranges.count)
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
        // Lets the cancel handler abort the URLSession task, not just the Swift one — else it keeps draining.
        let streamerBox = StreamerBox()
        do {
            try await withTaskCancellationHandler {
                while start + written <= end {
                    try Task.checkCancellation()
                    attempt += 1
                    let segStart = start + written
                    let url = await pool.url(segment: index, attempt: attempt)
                    let isMirror = url != plan.url

                    // Each `acquire()` must be balanced by exactly one `release()` on every exit path.
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
                        if isMirror, attempt < settings.maxAttempts {
                            await pool.demote(url)
                            continue
                        }
                        throw DownloadError.httpStatus(http.statusCode)
                    case .accept:
                        break
                    }
                    // Every 206 must describe the same total size — a wrong object must not merge in.
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
                        try await pumpBody(bytes, into: handle, streamer: streamer, ledger: ledger,
                                           segment: index, limiter: limiter, flushSize: flushSize,
                                           written: &written)
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
                        expectedTotal: plan.totalBytes
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
                        if (upgraded || isMirror), attempt < settings.maxAttempts {
                            try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                            continue
                        }
                        throw DownloadError.httpStatus(200)
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
                        session: session, request: req) { streamerBox.set($0) }
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
                          upgrade: UpgradeSignal? = nil) async throws {
        // `consumed` must be called per chunk: it releases the backpressure credit that resumes the task.
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
                await limiter?.pace(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Stop only on a flush boundary: `written` must equal the bytes on disk (the prefix).
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
        var seconds = min(6.0, pow(2.0, Double(attempt - 1)) * 0.4)
        if retryInterval > 0 { seconds = max(seconds, retryInterval) }
        if let header = response?.value(forHTTPHeaderField: "Retry-After"),
           let advised = Double(header.trimmingCharacters(in: .whitespaces)) {
            seconds = min(15.0, max(seconds, advised))
        }
        seconds += Double.random(in: 0...0.4)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
        try handle.truncate(atOffset: UInt64(size))
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

        private func maybeResume(now: Date) -> Data? {
            guard let meta else { return nil }
            if now.timeIntervalSince(lastResumeEmit) < 1.0 { return nil }
            lastResumeEmit = now
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
            return try? JSONEncoder().encode(cursor)
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
        completionHandler(RedirectSanitizer.followed(request, originalURL: task.originalRequest?.url))
    }
}

final class StreamerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ChunkStreamer?
    func set(_ streamer: ChunkStreamer) { lock.lock(); current = streamer; lock.unlock() }
    func cancel() { lock.lock(); let s = current; lock.unlock(); s?.cancelTask() }
}

/// A lock, not an actor: the pump reads this at every flush and must not hop executors.
final class UpgradeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() { lock.lock(); tripped = true; lock.unlock() }
    var isTripped: Bool { lock.lock(); defer { lock.unlock() }; return tripped }
}
