import XCTest
@testable import GoelCore

/// Serves HEAD with range support, then answers every ranged GET with its first `deliver` bytes and
/// stalls — a transfer that is mid-flight until it is cancelled.
final class StallingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _payload = Data()
    private static var _deliver = 0

    static func configure(payload: Data, deliver: Int) {
        lock.lock(); _payload = payload; _deliver = deliver; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let payload = Self._payload
        let deliver = Self._deliver
        Self.lock.unlock()
        guard let url = request.url else { return }
        if request.httpMethod == "HEAD" {
            let head = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Length": "\(payload.count)", "Accept-Ranges": "bytes", "ETag": "\"s1\""])!
            client?.urlProtocol(self, didReceive: head, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let (a, b) = ScriptedURLProtocol.range(request, total: payload.count) else { return }
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Range": "bytes \(a)-\(b)/\(payload.count)", "Content-Length": "\(b - a + 1)",
            "ETag": "\"s1\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.subdata(in: a..<min(b + 1, a + deliver)))
        // No finish: the segment sits mid-body until the task is cancelled.
    }
}

final class HTTPEngineUnwindTests: XCTestCase {

    private var tempDir: URL!
    private var restoreTrash: (() -> Void)?

    override func setUp() {
        super.setUp()
        restoreTrash = TestTrash.install()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        restoreTrash?()
        super.tearDown()
    }

    private struct NoCredentials: CredentialProviding {
        func basicAuthorization(forHost host: String) -> String? { nil }
    }

    /// Never answers, so a started job parks on its probe instead of touching the network.
    private func silentConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HLSJobLifecycleTests.SilentProtocol.self]
        return config
    }

    private func task(_ name: String) -> DownloadTask {
        DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!),
                     name: name, saveDirectory: tempDir.path)
    }

    /// A job that ignores cancellation and holds on for `seconds`.
    private func stubbornJob(seconds: Double) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
            }
        }
    }

    // MARK: concurrency#1

    func testAwaitUnwindReturnsAtTheDeadlineEvenIfTheJobIgnoresCancellation() async {
        let job = stubbornJob(seconds: 5)
        let start = Date()
        let finished = await HTTPEngine.awaitUnwind(job, timeout: 0.2)
        XCTAssertFalse(finished)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the bound must actually bound")
    }

    func testAwaitUnwindReportsAJobThatFinishesInTime() async {
        let job = Task<Void, Never> {}
        let finished = await HTTPEngine.awaitUnwind(job, timeout: 5)
        XCTAssertTrue(finished)
    }

    // MARK: concurrency#2

    func testPauseWhileResumeWaitsOutTheUnwindWins() async throws {
        let engine = HTTPEngine(configuration: silentConfig(), credentials: NoCredentials())
        let t = task("gen.bin")
        await engine.installUnwinding(t, job: stubbornJob(seconds: 0.5))
        let resuming = Task { await engine.resume(t.id) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await engine.pause(t.id)          // lands while resume() is parked on the unwind
        await resuming.value
        let running = await engine.hasLiveJob(t.id)
        XCTAssertFalse(running, "the later pause must not be overtaken by the earlier resume")
        await engine.remove(t.id, deleteData: false)
    }

    func testResumeStartsOnceTheUnwindFinishes() async throws {
        let engine = HTTPEngine(configuration: silentConfig(), credentials: NoCredentials())
        let t = task("gen2.bin")
        await engine.installUnwinding(t, job: stubbornJob(seconds: 0.2))
        await engine.resume(t.id)
        let running = await engine.hasLiveJob(t.id)
        XCTAssertTrue(running)
        await engine.remove(t.id, deleteData: false)
    }

    // MARK: engines#6 — final cursor

    private func stallingPlan(_ name: String, payload: Data, segments: Int) -> TransferPlan {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingURLProtocol.self]
        return TransferPlan(
            url: URL(string: "https://example.test/\(name)")!,
            destination: tempDir.appendingPathComponent(name),
            totalBytes: Int64(payload.count), acceptsRanges: true,
            etag: "\"s1\"", lastModified: nil, existingResume: nil,
            segmentCount: segments, session: URLSession(configuration: config),
            settings: RequestSettings(userAgent: "GoelTest/1.0", maxAttempts: 3, retryInterval: 0),
            maxBytesPerSecond: 0, flushSize: 64 * 1024)
    }

    private func completedBytes(_ data: Data?) throws -> (sum: Int64, ranges: Int) {
        let cursor = try JSONDecoder().decode(SegmentedTransfer.ResumeCursor.self, from: XCTUnwrap(data))
        return (cursor.completed.reduce(0, +), cursor.ranges.count)
    }

    func testCancelledTransferPublishesAFinalBarrieredCursor() async throws {
        let payload = ScriptedURLProtocol.payload(1024 * 1024)
        StallingURLProtocol.configure(payload: payload, deliver: 128 * 1024)
        let transfer = SegmentedTransfer(plan: stallingPlan("final.bin", payload: payload, segments: 4))
        let collected = Task { () -> [TransferProgress] in
            var all: [TransferProgress] = []
            for await p in transfer.progress { all.append(p) }
            return all
        }
        let running = Task { _ = try await transfer.run() }
        try await Task.sleep(nanoseconds: 800_000_000)
        running.cancel()
        _ = await running.result
        let updates = await collected.value

        let last = try XCTUnwrap(updates.last)
        XCTAssertTrue(last.isFinalCursor, "the unwind's last word is the cursor")
        let (sum, ranges) = try completedBytes(last.resumeData)
        XCTAssertEqual(ranges, 4)
        XCTAssertEqual(sum, 4 * 128 * 1024, "every flushed byte is claimed, not a 5 s-old snapshot")
    }

    func testPauseKeepsTheFinalCursorAndRefreshNeverDropsIt() async throws {
        let payload = ScriptedURLProtocol.payload(16 * 1024 * 1024)
        StallingURLProtocol.configure(payload: payload, deliver: HTTPEngine.flushSize)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingURLProtocol.self]
        let engine = HTTPEngine(configuration: config, profile: .high, credentials: NoCredentials())
        let t = task("paused.bin")
        let events = engine.events(for: t.id)
        let cursors = Task { () -> [Data] in
            var seen: [Data] = []
            for await event in events {
                if case .resumeDataUpdated(let data) = event { seen.append(data) }
            }
            return seen
        }
        await engine.add(t)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await engine.pause(t.id)

        // The unwind lands the final cursor on the engine's copy; wait for it.
        var stored: Data?
        for _ in 0..<100 {
            stored = await engine.tasks[t.id]?.resumeData
            if let stored, let (sum, ranges) = try? completedBytes(stored),
               sum == Int64(ranges) * Int64(HTTPEngine.flushSize) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let (sum, ranges) = try completedBytes(stored)
        XCTAssertGreaterThan(ranges, 1)
        XCTAssertEqual(sum, Int64(ranges) * Int64(HTTPEngine.flushSize), "the pause keeps every segment's flushed bytes")

        // A manager copy with no cursor and no bytes is NOT a restart order.
        var lagging = t
        lagging.resumeData = nil
        lagging.bytesDownloaded = 0
        await engine.refresh(lagging)
        let kept = await engine.tasks[t.id]?.resumeData
        XCTAssertEqual(kept, stored)

        await engine.remove(t.id, deleteData: true)
        let published = await cursors.value
        XCTAssertEqual(published.last, stored, "the manager heard the final cursor too")
    }
}
