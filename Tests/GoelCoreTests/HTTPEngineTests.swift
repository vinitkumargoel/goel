import XCTest
@testable import GoelCore

// MARK: - Stub URLProtocol

/// A configurable in-memory HTTP server used to drive `HTTPEngine` deterministically.
///
/// It serves a fixed payload and can be switched between three behaviours:
///  * range support + Content-Length (segmented path),
///  * no range support but with Content-Length (single-connection fallback),
///  * no Content-Length at all (streaming, unknown total).
/// Bodies are delivered in chunks with an optional inter-chunk delay so tests can
/// observe and interrupt in-flight progress.
final class StubURLProtocol: URLProtocol {

    struct Config {
        var data: Data
        var supportsRanges: Bool
        var sendContentLength: Bool
        var etag: String?
        var chunkSize: Int
        var chunkDelayMicros: UInt32
        /// Served as the `Content-Type` header (drives extension inference).
        var contentType: String = "application/octet-stream"
        /// Served as the `Content-Disposition` header when non-nil (drives the
        /// server-suggested filename).
        var contentDisposition: String? = nil
    }

    private static let lock = NSLock()
    private static var _config = Config(
        data: Data(), supportsRanges: true, sendContentLength: true,
        etag: "\"v1\"", chunkSize: 1 << 20, chunkDelayMicros: 0
    )

    static func set(_ config: Config) {
        lock.lock(); _config = config; lock.unlock()
    }
    static func current() -> Config {
        lock.lock(); defer { lock.unlock() }; return _config
    }

    /// User-Agent header observed on every request the engine issued. Used to
    /// prove the engine never sends a request without a UA (see the WAF/-1005
    /// regression).
    private static var _seenUserAgents: [String?] = []
    static func resetSeenUserAgents() { lock.lock(); _seenUserAgents = []; lock.unlock() }
    static func seenUserAgents() -> [String?] {
        lock.lock(); defer { lock.unlock() }; return _seenUserAgents
    }
    private static func record(userAgent: String?) {
        lock.lock(); _seenUserAgents.append(userAgent); lock.unlock()
    }

    /// Number of upcoming ranged GETs to answer with `429 Too Many Requests`
    /// (simulating a server that rate-limits concurrent range connections).
    /// Each such request decrements the counter; once drained, requests are
    /// served normally — so a client that retries with backoff still completes.
    private static var _force429Count = 0
    static func forceNext429s(_ n: Int) { lock.lock(); _force429Count = n; lock.unlock() }
    private static func consume429() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _force429Count > 0 { _force429Count -= 1; return true }
        return false
    }

    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped = true }

    override func startLoading() {
        let cfg = Self.current()
        guard let url = request.url else { return }
        Self.record(userAgent: request.value(forHTTPHeaderField: "User-Agent"))
        let total = cfg.data.count
        let method = request.httpMethod ?? "GET"

        var headers = ["Content-Type": cfg.contentType]
        if let cd = cfg.contentDisposition { headers["Content-Disposition"] = cd }
        if let etag = cfg.etag { headers["ETag"] = etag }
        if cfg.supportsRanges { headers["Accept-Ranges"] = "bytes" }

        // HEAD: headers only.
        if method == "HEAD" {
            if cfg.sendContentLength { headers["Content-Length"] = "\(total)" }
            sendResponse(url: url, status: 200, headers: headers)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // Simulated rate-limiting: answer the first N ranged GETs with 429.
        if method == "GET", request.value(forHTTPHeaderField: "Range") != nil, Self.consume429() {
            sendResponse(url: url, status: 429, headers: ["Content-Length": "11", "Retry-After": "0"])
            client?.urlProtocol(self, didLoad: Data("rate limited".utf8.prefix(11)))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // Ranged GET that the server honours -> 206 partial.
        if cfg.supportsRanges,
           let rangeHeader = request.value(forHTTPHeaderField: "Range"),
           let (start, end) = Self.parseRange(rangeHeader, total: total) {
            let slice = cfg.data.subdata(in: start..<(end + 1))
            headers["Content-Length"] = "\(slice.count)"
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
            sendResponse(url: url, status: 206, headers: headers)
            deliver(slice, cfg: cfg)
            return
        }

        // Full body -> 200.
        if cfg.sendContentLength { headers["Content-Length"] = "\(total)" }
        sendResponse(url: url, status: 200, headers: headers)
        deliver(cfg.data, cfg: cfg)
    }

    private func sendResponse(url: URL, status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func deliver(_ data: Data, cfg: Config) {
        var offset = 0
        let chunk = max(1, cfg.chunkSize)
        while offset < data.count {
            if stopped { return }
            let n = min(chunk, data.count - offset)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<(offset + n)))
            offset += n
            if cfg.chunkDelayMicros > 0 { usleep(cfg.chunkDelayMicros) }
        }
        if stopped { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Parses "bytes=start-end" (end may be open-ended).
    static func parseRange(_ header: String, total: Int) -> (Int, Int)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(parts.first ?? "") else { return nil }
        let end: Int
        if parts.count > 1, let e = Int(parts[1]) { end = e } else { end = total - 1 }
        guard start <= end, end < total else { return nil }
        return (start, end)
    }
}

// MARK: - Tests

final class HTTPEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Reset injected stub state so test order can't leak rate-limit / UA state.
        StubURLProtocol.forceNext429s(0)
        StubURLProtocol.resetSeenUserAgents()
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: Helpers

    private func makeEngine(profile: TrafficProfile = .high) -> HTTPEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return HTTPEngine(configuration: config, profile: profile)
    }

    private func deterministicData(_ count: Int) -> Data {
        var data = Data(capacity: count)
        for i in 0..<count { data.append(UInt8((i * 31 + 7) & 0xFF)) }
        return data
    }

    private func makeTask(name: String) -> DownloadTask {
        DownloadTask(
            source: .url(URL(string: "https://example.test/\(name)")!),
            name: name,
            saveDirectory: tempDir.path
        )
    }

    private func isCompleted(_ event: EngineEvent) -> Bool {
        if case .statusChanged(.completed) = event { return true }
        if case .failed = event { return true }
        return false
    }

    // MARK: (a) Full segmented download

    func testSegmentedDownloadStitchesExactBytes() async throws {
        let payload = deterministicData(300 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"abc\"", chunkSize: 32 * 1024, chunkDelayMicros: 0
        ))
        let engine = makeEngine()
        let task = makeTask(name: "segmented.bin")

        // Subscribe before adding so no events are missed.
        let stream = engine.events(for: task.id)
        await engine.add(task)

        var connectionCounts: [Int] = []
        var sawFinished = false
        let waiter = Task { () -> Void in
            for await event in stream {
                if case .progress(_, _, _, _, let c) = event { connectionCounts.append(c) }
                if case .finished = event { sawFinished = true }
                if isCompleted(event) { break }
            }
        }
        _ = await waiter.value

        XCTAssertTrue(sawFinished, "should emit .finished before completing")
        let written = try Data(contentsOf: tempDir.appendingPathComponent("segmented.bin"))
        XCTAssertEqual(written, payload, "stitched file must equal the source bytes")
        XCTAssertEqual(written.count, payload.count)
        XCTAssertTrue(connectionCounts.contains { $0 > 1 }, "a 300 KB file should use multiple segments")
    }

    // MARK: (a2) Every request carries a User-Agent (WAF / -1005 regression)

    func testEveryRequestSendsUserAgent() async throws {
        StubURLProtocol.resetSeenUserAgents()
        let payload = deterministicData(300 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"ua\"", chunkSize: 32 * 1024, chunkDelayMicros: 0
        ))
        let engine = makeEngine()
        _ = await drainAfterAdd(engine, makeTask(name: "ua.bin"))

        let seen = StubURLProtocol.seenUserAgents()
        XCTAssertFalse(seen.isEmpty, "the engine should have issued at least one request")
        for ua in seen {
            XCTAssertEqual(ua, HTTPEngine.userAgent,
                           "every outbound request must carry the client User-Agent; a missing UA causes some CDNs to reset the connection (-1005)")
        }
    }

    // MARK: (a3) Segments recover from 429 rate-limiting via retry/backoff

    func testSegmentsRetryThrough429RateLimiting() async throws {
        StubURLProtocol.resetSeenUserAgents()
        let payload = deterministicData(300 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"rl\"", chunkSize: 32 * 1024, chunkDelayMicros: 0
        ))
        // Answer the first 6 ranged GETs with 429 (Retry-After: 0 keeps the
        // test fast); a client that retries should still finish intact.
        StubURLProtocol.forceNext429s(6)

        let engine = makeEngine()
        let task = makeTask(name: "ratelimited.bin")
        let events = await drainAfterAdd(engine, task)

        let failed = events.contains { if case .failed = $0 { return true }; return false }
        let completed = events.contains { if case .statusChanged(.completed) = $0 { return true }; return false }
        XCTAssertFalse(failed, "429s should be retried, not surfaced as a failure")
        XCTAssertTrue(completed, "download should complete after retrying through rate-limiting")

        let written = try Data(contentsOf: tempDir.appendingPathComponent("ratelimited.bin"))
        XCTAssertEqual(written, payload, "bytes must be intact despite retried segments")

        // More requests than segments proves retries actually happened.
        XCTAssertGreaterThan(StubURLProtocol.seenUserAgents().count, 6,
                             "expected extra requests from the 6 forced 429 retries")
    }

    // MARK: (b) Progress events and final byte count

    func testProgressEventsReachTotal() async throws {
        let payload = deterministicData(256 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v2\"", chunkSize: 16 * 1024, chunkDelayMicros: 0
        ))
        let engine = makeEngine()
        let task = makeTask(name: "progress.bin")

        let events = await drainAfterAdd(engine, task)

        var resolvedTotal: Int64?
        var maxProgress: Int64 = 0
        var progressCount = 0
        for event in events {
            switch event {
            case .metadataResolved(_, let total, _): resolvedTotal = total
            case .progress(let bytes, _, _, _, _):
                progressCount += 1
                maxProgress = max(maxProgress, bytes)
            default: break
            }
        }
        XCTAssertEqual(resolvedTotal, Int64(payload.count))
        XCTAssertGreaterThan(progressCount, 0, "progress events must be emitted")
        XCTAssertEqual(maxProgress, Int64(payload.count), "final bytesDownloaded must equal totalBytes")
    }

    // MARK: (c) No range support -> single connection

    func testNoRangeSupportFallsBackToSingleConnection() async throws {
        let payload = deterministicData(200 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: false, sendContentLength: true,
            etag: nil, chunkSize: 16 * 1024, chunkDelayMicros: 0
        ))
        let engine = makeEngine()
        let task = makeTask(name: "norange.bin")

        let events = await drainAfterAdd(engine, task)

        let progressConnCounts = events.compactMap { event -> Int? in
            if case .progress(_, _, _, _, let c) = event { return c }
            return nil
        }
        XCTAssertFalse(progressConnCounts.isEmpty)
        // Single-connection fallback: no progress sample may report more than one
        // active connection (more than one would mean segmentation kicked in), and
        // at least one mid-transfer sample reports exactly 1. The terminal 100%
        // emit reports 0 by design — the engine clears the live connection count on
        // completion so the Connections panel doesn't show an open connection on a
        // finished transfer.
        XCTAssertTrue(progressConnCounts.contains(1), "single-connection transfer must report one active connection")
        XCTAssertTrue(progressConnCounts.allSatisfy { $0 <= 1 }, "fallback must never open more than one connection")

        let written = try Data(contentsOf: tempDir.appendingPathComponent("norange.bin"))
        XCTAssertEqual(written, payload)
    }

    // MARK: (d) Missing Content-Length -> unknown total, still downloads

    func testMissingContentLengthLeavesTotalUnknownButCompletes() async throws {
        let payload = deterministicData(180 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: false, sendContentLength: false,
            etag: nil, chunkSize: 16 * 1024, chunkDelayMicros: 0
        ))
        let engine = makeEngine()
        let task = makeTask(name: "nolength.bin")

        let events = await drainAfterAdd(engine, task)

        let sawMetadata = events.contains { if case .metadataResolved = $0 { return true }; return false }
        XCTAssertFalse(sawMetadata, "no Content-Length means total stays unknown (no metadataResolved)")

        let maxProgress = events.compactMap { event -> Int64? in
            if case .progress(let bytes, _, _, _, _) = event { return bytes }
            return nil
        }.max() ?? 0
        XCTAssertEqual(maxProgress, Int64(payload.count))

        let written = try Data(contentsOf: tempDir.appendingPathComponent("nolength.bin"))
        XCTAssertEqual(written, payload)
    }

    // MARK: (d2) Filename resolution from Content-Disposition / Content-Type

    /// Reproduces the opaque-CDN-URL bug: the URL's last path component is a huge
    /// query token (no extension, well over NAME_MAX), which previously failed the
    /// write with "the file name … is invalid". The server's `Content-Disposition`
    /// supplies the real name; the engine renames the task and saves correctly.
    func testRenamesFromContentDisposition() async throws {
        let payload = deterministicData(120 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"cd\"", chunkSize: 16 * 1024, chunkDelayMicros: 0,
            contentType: "video/mp4",
            contentDisposition: "attachment; filename=\"Holiday Clip.mp4\""
        ))
        let engine = makeEngine()
        // A 320-char opaque token with no extension — the kind that broke before.
        let token = String(repeating: "A1b2C3d4", count: 40)
        let url = URL(string: "https://video-downloads.example/\(token)")!
        let task = DownloadTask(source: .url(url),
                                name: DownloadManager.defaultName(for: .url(url)),
                                saveDirectory: tempDir.path)

        let events = await drainAfterAdd(engine, task)

        let resolved = events.compactMap { e -> String? in
            if case .nameResolved(let n) = e { return n }; return nil
        }
        XCTAssertEqual(resolved.last, "Holiday Clip.mp4", "should adopt the Content-Disposition filename")
        let written = try Data(contentsOf: tempDir.appendingPathComponent("Holiday Clip.mp4"))
        XCTAssertEqual(written, payload, "bytes must land under the resolved name")
    }

    /// No Content-Disposition + a URL name without an extension -> infer the
    /// extension from Content-Type.
    func testInfersExtensionFromContentType() async throws {
        let payload = deterministicData(64 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"ct\"", chunkSize: 16 * 1024, chunkDelayMicros: 0,
            contentType: "application/pdf"
        ))
        let engine = makeEngine()
        let task = makeTask(name: "report")   // no extension
        let events = await drainAfterAdd(engine, task)

        let resolved = events.compactMap { e -> String? in
            if case .nameResolved(let n) = e { return n }; return nil
        }
        XCTAssertEqual(resolved.last, "report.pdf")
        let written = try Data(contentsOf: tempDir.appendingPathComponent("report.pdf"))
        XCTAssertEqual(written, payload)
    }

    /// A URL name that is already a good filename must not be renamed (no churn,
    /// and resume relies on the name staying put).
    func testKeepsGoodFilename() async throws {
        let payload = deterministicData(64 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"ok\"", chunkSize: 16 * 1024, chunkDelayMicros: 0,
            contentType: "application/octet-stream"
        ))
        let engine = makeEngine()
        let task = makeTask(name: "archive.zip")
        let events = await drainAfterAdd(engine, task)

        let renamed = events.contains { if case .nameResolved = $0 { return true }; return false }
        XCTAssertFalse(renamed, "a good name with an extension should not be renamed")
        let written = try Data(contentsOf: tempDir.appendingPathComponent("archive.zip"))
        XCTAssertEqual(written, payload)
    }

    // MARK: (e) Pause stops progress

    func testPauseStopsProgress() async throws {
        let payload = deterministicData(512 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v3\"", chunkSize: 16 * 1024, chunkDelayMicros: 25_000
        ))
        let engine = makeEngine()
        let task = makeTask(name: "pause.bin")

        // Track the latest reported bytesDownloaded via a thread-safe box.
        let box = ProgressBox()
        let stream = engine.events(for: task.id)
        let consumer = Task {
            for await event in stream {
                if case .progress(let bytes, _, _, _, _) = event { box.set(bytes) }
            }
        }

        await engine.add(task)

        // Let some progress accumulate, then pause.
        try await Task.sleep(nanoseconds: 200_000_000)
        await engine.pause(task.id)

        // Settle, snapshot, wait again, snapshot.
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterPause = box.get()
        try await Task.sleep(nanoseconds: 400_000_000)
        let later = box.get()

        consumer.cancel()

        XCTAssertGreaterThan(afterPause, 0, "some bytes should download before pausing")
        XCTAssertLessThan(afterPause, Int64(payload.count), "pause should happen mid-download")
        XCTAssertEqual(later, afterPause, "no further progress after pause")
    }

    // MARK: Live network smoke test (opt-in)

    /// End-to-end against the real Hetzner speed-test server, which both
    /// rejects UA-less requests (-1005) and rate-limits concurrent ranges
    /// (429) — the exact conditions that broke the app. Skipped unless
    /// `GOEL_LIVE_NET=1` so the normal suite stays hermetic.
    func testLiveHetznerDownloadCompletes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOEL_LIVE_NET"] == "1",
                          "set GOEL_LIVE_NET=1 to run the live network test")
        let engine = HTTPEngine(profile: .high)   // real session, 16-way fan-out
        let task = DownloadTask(
            source: .url(URL(string: "https://ash-speed.hetzner.com/100MB.bin")!),
            name: "100MB.bin",
            saveDirectory: tempDir.path
        )
        let stream = engine.events(for: task.id)
        await engine.add(task)

        var failure: DownloadError?
        var completed = false
        let waiter = Task { () -> Void in
            for await event in stream {
                if case .failed(let e) = event { failure = e; break }
                if case .statusChanged(.completed) = event { completed = true; break }
            }
        }
        _ = await waiter.value

        XCTAssertNil(failure, "live download must not fail: \(String(describing: failure))")
        XCTAssertTrue(completed, "live download should reach .completed")
        let written = try Data(contentsOf: tempDir.appendingPathComponent("100MB.bin"))
        XCTAssertEqual(written.count, 100 * 1024 * 1024, "must fetch the full 100 MB")
    }

    // MARK: Shared drain helper

    private func drainAfterAdd(_ engine: HTTPEngine, _ task: DownloadTask) async -> [EngineEvent] {
        let stream = engine.events(for: task.id)
        await engine.add(task)
        return await withTaskGroup(of: [EngineEvent]?.self) { group in
            group.addTask {
                var collected: [EngineEvent] = []
                for await event in stream {
                    collected.append(event)
                    if case .statusChanged(.completed) = event { return collected }
                    if case .failed = event { return collected }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? []
        }
    }
}

/// Thread-safe holder for the latest progress byte count.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func set(_ v: Int64) { lock.lock(); value = max(value, v); lock.unlock() }
    func get() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
}
