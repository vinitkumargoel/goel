import Foundation

// MARK: - Transfer mechanics

/// The byte-moving core: segmented (multi-connection) and single-connection
/// downloads, the per-host/global connection budget, and segment planning.
/// Split out of ``HTTPEngine`` so the orchestration in `run()` stays readable;
/// the byte pumps are `nonisolated` so they run off the actor (one hop per flush).
extension HTTPEngine {

    // MARK: Segmented download

    func segmentedDownload(id: UUID, url: URL, total: Int64, probe: ProbeResult, fileURL: URL, limiter: RateLimiter?, settings: RequestSettings) async throws {
        var ranges: [Range64]
        var restored: [Int: Int64] = [:]
        let host = url.host

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
            let count = computeSegmentCount(total, host: host)
            ranges = makeRanges(total: total, count: count)
            try preallocate(fileURL, size: total)
        }

        // Charge this download's connections to the global / per-host budget and
        // release them on EVERY exit — clean completion, failure, or the task
        // group below unwinding on pause/remove cancellation.
        let reserved = ranges.count
        reserveConnections(host: host, count: reserved)
        defer { releaseConnections(host: host, count: reserved) }

        segmentBytes[id] = restored.isEmpty
            ? Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, Int64(0)) })
            : restored
        connections[id] = ranges.count
        tasks[id]?.connectionCount = ranges.count
        cursorMeta[id] = CursorMeta(etag: probe.etag, lastModified: probe.lastModified, total: total, ranges: ranges)

        let session = self.session
        // One governor per download: it begins at the requested fan-out and
        // adapts down to the server's real concurrent-connection ceiling.
        let governor = ConnectionGovernor(limit: ranges.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, range) in ranges.enumerated() {
                let already = segmentBytes[id]?[i] ?? 0
                let segStart = range.start + already
                if segStart > range.end { continue } // segment already complete
                group.addTask {
                    try await self.downloadSegment(session: session, governor: governor, limiter: limiter, settings: settings, id: id, url: url, index: i, from: segStart, to: range.end, fileURL: fileURL)
                }
            }
            try await group.waitForAll()
        }
    }

    /// `nonisolated` so the byte pump runs OFF the actor — otherwise every segment
    /// would serialize through the actor executor (one hop per byte), defeating the
    /// whole point of segmented downloading. It only hops back to the actor (via
    /// `await advance`) once per ~64 KiB flush.
    private nonisolated func downloadSegment(session: URLSession, governor: ConnectionGovernor, limiter: RateLimiter?, settings: RequestSettings, id: UUID, url: URL, index: Int, from start: Int64, to end: Int64, fileURL: URL) async throws {
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
                var req = makeRequest(url, userAgent: settings.userAgent)
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
                    buffer.reserveCapacity(Self.flushSize)
                    // Cooperative cancellation flows from the AsyncBytes iterator,
                    // so we check once per flush rather than once per byte (the
                    // latter burns ~16% of a core at speed for no added safety).
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= Self.flushSize {
                            try Task.checkCancellation()
                            try handle.write(contentsOf: buffer)
                            written += Int64(buffer.count)
                            await advance(id, segment: index, by: buffer.count)
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
                        await advance(id, segment: index, by: buffer.count)
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

    func singleDownload(id: UUID, url: URL, fileURL: URL, limiter: RateLimiter?, settings: RequestSettings) async throws {
        // SF8: truncate to zero on (re)create — `createFile` is a no-op when the
        // file already exists, which would leave stale trailing bytes if the new
        // download is shorter. `Data().write` both creates and truncates.
        try Data().write(to: fileURL)

        // A single connection still counts against the aggregate budget.
        let host = url.host
        reserveConnections(host: host, count: 1)
        defer { releaseConnections(host: host, count: 1) }

        segmentBytes[id] = [0: 0]
        connections[id] = 1
        tasks[id]?.connectionCount = 1
        cursorMeta[id] = nil

        try await streamSingle(session: session, limiter: limiter, settings: settings, id: id, url: url, fileURL: fileURL)
    }

    /// `nonisolated` single-connection body pump (see ``downloadSegment`` for why).
    private nonisolated func streamSingle(session: URLSession, limiter: RateLimiter?, settings: RequestSettings, id: UUID, url: URL, fileURL: URL) async throws {
        // Retry only the connect/status phase: the no-range fallback can't
        // resume a partial body, so a mid-stream drop fails (rather than
        // silently restarting and double-counting progress).
        var attempt = 0
        let bytes: URLSession.AsyncBytes
        while true {
            attempt += 1
            let req = makeRequest(url, userAgent: settings.userAgent)
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
            buffer.reserveCapacity(Self.flushSize)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.flushSize {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    await advance(id, segment: 0, by: buffer.count)
                    // Pace against the profile's download cap (no-op when unlimited).
                    await limiter?.pace(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                await advance(id, segment: 0, by: buffer.count)
                await limiter?.pace(buffer.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    // MARK: Connection budget

    /// Charge `count` connections to the global and per-host budgets when a
    /// download's segments start. Balanced by `releaseConnections`.
    private func reserveConnections(host: String?, count: Int) {
        totalConnections += count
        if let host { connectionsByHost[host, default: 0] += count }
    }

    /// Return `count` connections to the budgets when a download ends (cleanly,
    /// by failure, or by pause/remove cancellation).
    private func releaseConnections(host: String?, count: Int) {
        totalConnections = max(0, totalConnections - count)
        if let host {
            let remaining = (connectionsByHost[host] ?? 0) - count
            if remaining > 0 { connectionsByHost[host] = remaining }
            else { connectionsByHost[host] = nil }
        }
    }

    // MARK: Segmenting

    private func computeSegmentCount(_ total: Int64, host: String?) -> Int {
        // The Low profile opts out of extra connections entirely (its
        // `enableExtraConnections` flag): one connection, no segmentation.
        guard profile.enableExtraConnections else { return 1 }
        var want = max(1, profile.maxConnectionsPerServer)
        // Share the per-server budget with any other in-flight download to the
        // same host, and the global budget across every concurrent download, so
        // the profile's advertised caps hold in aggregate (floor of 1 so a new
        // download never stalls with zero connections).
        let hostInUse = host.flatMap { connectionsByHost[$0] } ?? 0
        want = min(want, max(1, profile.maxConnectionsPerServer - hostInUse))
        want = min(want, max(1, profile.maxConnections - totalConnections))
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
}
