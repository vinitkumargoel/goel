import XCTest
@testable import GoelCore

final class StubURLProtocol: URLProtocol {

    struct Config {
        var data: Data
        var supportsRanges: Bool
        var sendContentLength: Bool
        var etag: String?
        var chunkSize: Int
        var chunkDelayMicros: UInt32
        var contentType: String = "application/octet-stream"
        var contentDisposition: String? = nil
        var holdUnrangedBodyAt: Int? = nil
        var unrangedData: Data? = nil
        var unrangedETagOverride: String? = nil
    }

    private static let lock = NSLock()
    private static var _config = Config(
        data: Data(), supportsRanges: true, sendContentLength: true,
        etag: "\"v1\"", chunkSize: 1 << 20, chunkDelayMicros: 0
    )

    static func set(_ config: Config) {
        lock.lock()
        _config = config
        // Every static knob resets with the config, or test order leaks a hold, a recorded range or a pending flap-back into the next test.
        _unrangedReleased = false
        _seenRangeHeaders = []
        _force200MultiByteCount = 0
        lock.unlock()
    }
    static func current() -> Config {
        lock.lock(); defer { lock.unlock() }; return _config
    }

    private static var _seenUserAgents: [String?] = []
    static func resetSeenUserAgents() { lock.lock(); _seenUserAgents = []; lock.unlock() }
    static func seenUserAgents() -> [String?] {
        lock.lock(); defer { lock.unlock() }; return _seenUserAgents
    }
    private static func record(userAgent: String?) {
        lock.lock(); _seenUserAgents.append(userAgent); lock.unlock()
    }

    private static var _force429Count = 0
    static func forceNext429s(_ n: Int) { lock.lock(); _force429Count = n; lock.unlock() }
    private static func consume429() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _force429Count > 0 { _force429Count -= 1; return true }
        return false
    }

    private static var _unrangedReleased = false
    static func releaseUnrangedBody() { lock.lock(); _unrangedReleased = true; lock.unlock() }
    private static func unrangedBodyReleased() -> Bool {
        lock.lock(); defer { lock.unlock() }; return _unrangedReleased
    }

    private static var _seenRangeHeaders: [String] = []
    static func seenRangeHeaders() -> [String] {
        lock.lock(); defer { lock.unlock() }; return _seenRangeHeaders
    }
    private static func record(range: String) {
        lock.lock(); _seenRangeHeaders.append(range); lock.unlock()
    }

    /// Single-byte (midpoint probe) ranges are exempt, so this knob can't eat the probe under test.
    private static var _force200MultiByteCount = 0
    static func force200ForMultiByteRangedGETs(_ n: Int) {
        lock.lock(); _force200MultiByteCount = n; lock.unlock()
    }
    private static func consumeForce200() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _force200MultiByteCount > 0 { _force200MultiByteCount -= 1; return true }
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
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        if let rangeHeader { Self.record(range: rangeHeader) }

        var headers = ["Content-Type": cfg.contentType]
        if let cd = cfg.contentDisposition { headers["Content-Disposition"] = cd }
        if let etag = cfg.etag { headers["ETag"] = etag }
        if cfg.supportsRanges { headers["Accept-Ranges"] = "bytes" }

        if method == "HEAD" {
            if cfg.sendContentLength { headers["Content-Length"] = "\(total)" }
            sendResponse(url: url, status: 200, headers: headers)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if method == "GET", rangeHeader != nil, Self.consume429() {
            sendResponse(url: url, status: 429, headers: ["Content-Length": "11", "Retry-After": "0"])
            client?.urlProtocol(self, didLoad: Data("rate limited".utf8.prefix(11)))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if cfg.supportsRanges,
           let rangeHeader,
           let (start, end) = Self.parseRange(rangeHeader, total: total) {
            if end > start, Self.consumeForce200() {
                if cfg.sendContentLength { headers["Content-Length"] = "\(total)" }
                sendResponse(url: url, status: 200, headers: headers)
                deliver(cfg.data, cfg: cfg)
                return
            }
            let slice = cfg.data.subdata(in: start..<(end + 1))
            headers["Content-Length"] = "\(slice.count)"
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
            sendResponse(url: url, status: 206, headers: headers)
            deliver(slice, cfg: cfg)
            return
        }

        let unranged = rangeHeader == nil
        let body = unranged ? (cfg.unrangedData ?? cfg.data) : cfg.data
        if unranged, let override = cfg.unrangedETagOverride { headers["ETag"] = override }
        if cfg.sendContentLength { headers["Content-Length"] = "\(body.count)" }
        sendResponse(url: url, status: 200, headers: headers)
        deliver(body, cfg: cfg, holdAt: unranged ? cfg.holdUnrangedBodyAt : nil)
    }

    private func sendResponse(url: URL, status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    /// Bodies deliver inline on URLSession's shared loader thread, so a parked body would wedge every other request — held deliveries need their own queue.
    private static let heldBodyQueue = DispatchQueue(label: "StubURLProtocol.held-body",
                                                     attributes: .concurrent)

    private func deliver(_ data: Data, cfg: Config, holdAt: Int? = nil) {
        guard let holdAt else { return deliverBody(data, cfg: cfg, holdAt: nil) }
        Self.heldBodyQueue.async { self.deliverBody(data, cfg: cfg, holdAt: holdAt) }
    }

    private func deliverBody(_ data: Data, cfg: Config, holdAt: Int?) {
        var offset = 0
        let chunk = max(1, cfg.chunkSize)
        while offset < data.count {
            if stopped { return }
            if let holdAt, offset >= holdAt {
                while !Self.unrangedBodyReleased() && !stopped { usleep(10_000) }
                if stopped { return }
            }
            let n = min(chunk, data.count - offset)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<(offset + n)))
            offset += n
            if cfg.chunkDelayMicros > 0 { usleep(cfg.chunkDelayMicros) }
        }
        if stopped { return }
        client?.urlProtocolDidFinishLoading(self)
    }

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

final class HTTPEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        StubURLProtocol.forceNext429s(0)
        StubURLProtocol.resetSeenUserAgents()
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

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

    func testSegmentedDownloadStitchesExactBytes() async throws {
        let payload = deterministicData(300 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"abc\"", chunkSize: 32 * 1024, chunkDelayMicros: 0
        ))
        let engine = makeEngine()
        let task = makeTask(name: "segmented.bin")

        // Subscribe before adding, or the first events are missed.
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

    func testSegmentsRetryThrough429RateLimiting() async throws {
        StubURLProtocol.resetSeenUserAgents()
        let payload = deterministicData(300 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"rl\"", chunkSize: 32 * 1024, chunkDelayMicros: 0
        ))
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

        XCTAssertGreaterThan(StubURLProtocol.seenUserAgents().count, 6,
                             "expected extra requests from the 6 forced 429 retries")
    }

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
        XCTAssertTrue(progressConnCounts.contains(1), "single-connection transfer must report one active connection")
        XCTAssertTrue(progressConnCounts.allSatisfy { $0 <= 1 }, "fallback must never open more than one connection")

        let written = try Data(contentsOf: tempDir.appendingPathComponent("norange.bin"))
        XCTAssertEqual(written, payload)
    }

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

    /// Regression: a last path component over NAME_MAX with no extension used to fail the write with "the file name … is invalid".
    func testRenamesFromContentDisposition() async throws {
        let payload = deterministicData(120 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"cd\"", chunkSize: 16 * 1024, chunkDelayMicros: 0,
            contentType: "video/mp4",
            contentDisposition: "attachment; filename=\"Holiday Clip.mp4\""
        ))
        let engine = makeEngine()
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

    func testInfersExtensionFromContentType() async throws {
        let payload = deterministicData(64 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"ct\"", chunkSize: 16 * 1024, chunkDelayMicros: 0,
            contentType: "application/pdf"
        ))
        let engine = makeEngine()
        let task = makeTask(name: "report")
        let events = await drainAfterAdd(engine, task)

        let resolved = events.compactMap { e -> String? in
            if case .nameResolved(let n) = e { return n }; return nil
        }
        XCTAssertEqual(resolved.last, "report.pdf")
        let written = try Data(contentsOf: tempDir.appendingPathComponent("report.pdf"))
        XCTAssertEqual(written, payload)
    }

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

    func testResolveMetadataReturnsNameAndSize() async throws {
        let payload = deterministicData(250 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"m\"", chunkSize: 64 * 1024, chunkDelayMicros: 0,
            contentType: "video/mp4",
            contentDisposition: "attachment; filename=\"Clip.mp4\""
        ))
        let engine = makeEngine()
        let url = URL(string: "https://example.test/opaque-token")!
        let meta = await engine.resolveMetadata(for: url, currentName: "opaque-token")
        XCTAssertEqual(meta.name, "Clip.mp4")
        XCTAssertEqual(meta.totalBytes, Int64(payload.count))
        XCTAssertTrue(meta.reachable)
    }

    func testManagerResolveMetadataForHTTP() async throws {
        let payload = deterministicData(120 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"mm\"", chunkSize: 32 * 1024, chunkDelayMicros: 0,
            contentType: "application/pdf"
        ))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let manager = DownloadManager(
            httpEngine: HTTPEngine(configuration: config),
            torrentEngine: FakeEngine(kind: .torrent),
            store: nil
        )
        let preview = await manager.resolveMetadata(for: .url(URL(string: "https://example.test/report")!))
        XCTAssertEqual(preview.kind, .http)
        XCTAssertEqual(preview.suggestedName, "report.pdf", "name + inferred extension")
        XCTAssertEqual(preview.totalBytes, Int64(payload.count))
        XCTAssertNil(preview.note)
    }

    func testPauseStopsProgress() async throws {
        let payload = deterministicData(512 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v3\"", chunkSize: 8 * 1024, chunkDelayMicros: 50_000
        ))
        let engine = makeEngine()
        let task = makeTask(name: "pause.bin")

        let box = ProgressBox()
        let stream = engine.events(for: task.id)
        let consumer = Task {
            for await event in stream {
                if case .progress(let bytes, _, _, _, _) = event { box.set(bytes) }
            }
        }

        await engine.add(task)

        // Pause on the first observed progress, never after a fixed sleep: on a fast machine the parallel segments finish inside the sleep and the test fails.
        for _ in 0..<400 where box.get() == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await engine.pause(task.id)

        try await Task.sleep(nanoseconds: 400_000_000)
        let afterPause = box.get()
        try await Task.sleep(nanoseconds: 400_000_000)
        let later = box.get()

        consumer.cancel()

        XCTAssertGreaterThan(afterPause, 0, "some bytes should download before pausing")
        XCTAssertLessThan(afterPause, Int64(payload.count), "pause should happen mid-download")
        XCTAssertEqual(later, afterPause, "no further progress after pause")
    }

    /// Hits a real server that rejects UA-less requests (-1005) and rate-limits concurrent ranges (429); gated on `GOEL_LIVE_NET=1` so the suite stays hermetic.
    func testLiveHetznerDownloadCompletes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOEL_LIVE_NET"] == "1",
                          "set GOEL_LIVE_NET=1 to run the live network test")
        let engine = HTTPEngine(profile: .high)
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

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func set(_ v: Int64) { lock.lock(); value = max(value, v); lock.unlock() }
    func get() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
}
