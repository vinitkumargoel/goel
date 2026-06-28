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

    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped = true }

    override func startLoading() {
        let cfg = Self.current()
        guard let url = request.url else { return }
        let total = cfg.data.count
        let method = request.httpMethod ?? "GET"

        var headers = ["Content-Type": "application/octet-stream"]
        if let etag = cfg.etag { headers["ETag"] = etag }
        if cfg.supportsRanges { headers["Accept-Ranges"] = "bytes" }

        // HEAD: headers only.
        if method == "HEAD" {
            if cfg.sendContentLength { headers["Content-Length"] = "\(total)" }
            sendResponse(url: url, status: 200, headers: headers)
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
        XCTAssertTrue(progressConnCounts.allSatisfy { $0 == 1 }, "fallback must use a single connection")

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
