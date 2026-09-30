import XCTest
@testable import GoelCore

/// A URLProtocol whose every reply is decided by a per-test closure, so a test can script a misbehaving server.
final class ScriptedURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()
    private static var _handler: (@Sendable (URLRequest) -> Reply)?
    private static var _requests: [URLRequest] = []

    static func script(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); _handler = handler; _requests = []; lock.unlock()
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let handler = Self._handler
        Self.lock.unlock()
        guard let url = request.url, let handler else { return }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD", !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    static func payload(_ count: Int) -> Data {
        var data = Data(capacity: count)
        for i in 0..<count { data.append(UInt8((i * 31 + 7) & 0xFF)) }
        return data
    }

    /// (start, end) of a `bytes=a-b` request, clamped to the payload.
    static func range(_ request: URLRequest, total: Int) -> (Int, Int)? {
        guard let header = request.value(forHTTPHeaderField: "Range") else { return nil }
        return StubURLProtocol.parseRange(header, total: total)
    }

    /// A correct 206 for `start...end`.
    static func partial(_ payload: Data, _ start: Int, _ end: Int, etag: String?) -> Reply {
        var headers = ["Content-Range": "bytes \(start)-\(end)/\(payload.count)",
                       "Content-Length": "\(end - start + 1)", "Accept-Ranges": "bytes"]
        if let etag { headers["ETag"] = etag }
        return Reply(status: 206, headers: headers, body: payload.subdata(in: start..<(end + 1)))
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class HTTPRangeValidationTests: XCTestCase {

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

    private func plan(_ name: String, total: Int, segments: Int, etag: String? = "\"v1\"",
                      maxAttempts: Int = 10, resume: Data? = nil) -> TransferPlan {
        TransferPlan(
            url: URL(string: "https://example.test/\(name)")!,
            destination: tempDir.appendingPathComponent(name),
            totalBytes: Int64(total), acceptsRanges: true,
            etag: etag, lastModified: nil, existingResume: resume,
            segmentCount: segments, session: ScriptedURLProtocol.makeSession(),
            settings: RequestSettings(userAgent: "GoelTest/1.0", maxAttempts: maxAttempts, retryInterval: 0),
            maxBytesPerSecond: 0, flushSize: 64 * 1024)
    }

    private func run(_ plan: TransferPlan) async throws -> TransferOutcome {
        let transfer = SegmentedTransfer(plan: plan)
        let drain = Task { for await _ in transfer.progress {} }
        defer { drain.cancel() }
        return try await transfer.run()
    }

    // MARK: ENG-5 If-Range

    func testSegmentsSendIfRangeWithStrongETag() async throws {
        let payload = ScriptedURLProtocol.payload(256 * 1024)
        ScriptedURLProtocol.script { req in
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            return ScriptedURLProtocol.partial(payload, a, b, etag: "\"v1\"")
        }
        _ = try await run(plan("ifrange.bin", total: payload.count, segments: 4))
        let ranged = ScriptedURLProtocol.requests.filter { $0.value(forHTTPHeaderField: "Range") != nil }
        XCTAssertFalse(ranged.isEmpty)
        for req in ranged {
            XCTAssertEqual(req.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        }
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("ifrange.bin")), payload)
    }

    func testWeakETagIsNeverSentAsIfRange() async throws {
        let payload = ScriptedURLProtocol.payload(128 * 1024)
        ScriptedURLProtocol.script { req in
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            return ScriptedURLProtocol.partial(payload, a, b, etag: "W/\"v1\"")
        }
        _ = try await run(plan("weak.bin", total: payload.count, segments: 2, etag: "W/\"v1\""))
        XCTAssertTrue(ScriptedURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-Range") == nil })
    }

    func testServerHonouringIfRangeWithFullBodyFailsAsRemoteFileChanged() async throws {
        let payload = ScriptedURLProtocol.payload(128 * 1024)
        // The entity is now v2: an RFC server answers If-Range "v1" with the whole new body.
        ScriptedURLProtocol.script { _ in
            .init(status: 200, headers: ["ETag": "\"v2\"", "Content-Length": "\(payload.count)"], body: payload)
        }
        do {
            _ = try await run(plan("changed200.bin", total: payload.count, segments: 2, maxAttempts: 2))
            XCTFail("a changed entity must not complete")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .remoteFileChanged)
        }
    }

    func testSameSizeETagFlipMidDownloadIsRejected() async throws {
        let payload = ScriptedURLProtocol.payload(128 * 1024)
        // A server ignoring If-Range but serving v2 bytes under a v2 ETag: sizes match, entity doesn't.
        ScriptedURLProtocol.script { req in
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            return ScriptedURLProtocol.partial(payload, a, b, etag: "\"v2\"")
        }
        do {
            _ = try await run(plan("flip.bin", total: payload.count, segments: 2, maxAttempts: 2))
            XCTFail("a spliced entity must not complete")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .remoteFileChanged)
        }
    }

    // MARK: ENG-6 range validation

    func testWrongStartIsRetriedNotWrittenAtOurOffset() async throws {
        let payload = ScriptedURLProtocol.payload(256 * 1024)
        let lies = LockedCounter(3)
        ScriptedURLProtocol.script { req in
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            // A broken proxy answering from byte 0, whatever was asked.
            if a > 0, lies.take() {
                return ScriptedURLProtocol.partial(payload, 0, b - a, etag: "\"v1\"")
            }
            return ScriptedURLProtocol.partial(payload, a, b, etag: "\"v1\"")
        }
        _ = try await run(plan("wrongstart.bin", total: payload.count, segments: 4))
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("wrongstart.bin")), payload)
    }

    func testOvershootingRangeIsClampedToTheSegment() async throws {
        let payload = ScriptedURLProtocol.payload(256 * 1024)
        // Every reply runs to EOF, spilling into later segments if written blindly.
        ScriptedURLProtocol.script { req in
            let (a, _) = ScriptedURLProtocol.range(req, total: payload.count)!
            return ScriptedURLProtocol.partial(payload, a, payload.count - 1, etag: "\"v1\"")
        }
        let outcome = try await run(plan("overshoot.bin", total: payload.count, segments: 4))
        XCTAssertEqual(outcome.bytesWritten, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("overshoot.bin")), payload)
    }

    func testContentRangeParsing() {
        XCTAssertEqual(SegmentedTransfer.contentRange(parsing: "bytes 100-199/1000")?.start, 100)
        XCTAssertEqual(SegmentedTransfer.contentRange(parsing: "bytes 100-199/*")?.end, 199)
        XCTAssertNil(SegmentedTransfer.contentRange(parsing: "bytes */1000"))
        XCTAssertNil(SegmentedTransfer.contentRange(parsing: "bytes 200-100/1000"))
        XCTAssertNil(SegmentedTransfer.contentRange(parsing: "items 0-1/2"))
    }

    // MARK: ENG-9 retry budget

    func testShortRepliesThatMakeProgressDoNotExhaustTheRetryBudget() async throws {
        let payload = ScriptedURLProtocol.payload(256 * 1024)
        let cap = 32 * 1024
        // A CDN capping every 206: each segment needs 4 requests, far past a 2-attempt budget.
        ScriptedURLProtocol.script { req in
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            return ScriptedURLProtocol.partial(payload, a, min(b, a + cap - 1), etag: "\"v1\"")
        }
        _ = try await run(plan("capped.bin", total: payload.count, segments: 2, maxAttempts: 2))
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("capped.bin")), payload)
    }

    func testBackoffIsJitteredProportionallyAndHonoursRetryAfter() {
        let samples = (0..<200).map { _ in
            SegmentedTransfer.backoffSeconds(attempt: 10, retryInterval: 0, retryAfter: nil)
        }
        XCTAssertGreaterThanOrEqual(samples.min()!, 3.0)
        XCTAssertLessThanOrEqual(samples.max()!, 9.0)
        XCTAssertGreaterThan(samples.max()! - samples.min()!, 1.0, "retries must spread, not fire in lockstep")
        let advised = SegmentedTransfer.backoffSeconds(attempt: 1, retryInterval: 0, retryAfter: "5")
        XCTAssertGreaterThanOrEqual(advised, 5.0)
    }

    // MARK: ENG-14 / FAIL-10 cursor validation

    func testCursorWhoseRangesOverlapIsRejected() {
        let r = SegmentedTransfer.Range64.self
        let overlapping = SegmentedTransfer.ResumeCursor(
            etag: "\"v1\"", lastModified: nil, totalBytes: 1000,
            ranges: [r.init(start: 0, end: 499), r.init(start: 0, end: 499)], completed: [500, 500])
        XCTAssertFalse(SegmentedTransfer.cursorIsWellFormed(overlapping, total: 1000))

        let gapped = SegmentedTransfer.ResumeCursor(
            etag: nil, lastModified: nil, totalBytes: 1000,
            ranges: [r.init(start: 0, end: 399), r.init(start: 500, end: 999)], completed: [0, 0])
        XCTAssertFalse(SegmentedTransfer.cursorIsWellFormed(gapped, total: 1000))

        let tiled = SegmentedTransfer.ResumeCursor(
            etag: nil, lastModified: nil, totalBytes: 1000,
            ranges: [r.init(start: 500, end: 999), r.init(start: 0, end: 499)], completed: [10, 20])
        XCTAssertTrue(SegmentedTransfer.cursorIsWellFormed(tiled, total: 1000))
    }

    func testResumeRejectionNamesTheFailedGuard() throws {
        let r = SegmentedTransfer.Range64.self
        let cursor = SegmentedTransfer.ResumeCursor(
            etag: nil, lastModified: nil, totalBytes: 1000,
            ranges: [r.init(start: 0, end: 999)], completed: [500])
        let data = try JSONEncoder().encode(cursor)
        let p = plan("noval.bin", total: 1000, segments: 1, etag: nil, resume: data)
        XCTAssertEqual(SegmentedTransfer.resumeRejection(plan: p, total: 1000, multiPath: false), .unprovable)
        XCTAssertEqual(SegmentedTransfer.resumeRejection(plan: p, total: 2000, multiPath: false), .sizeChanged)
    }

    // MARK: FFI-6 header safety

    func testHeaderSafetyRejectsLineBreaksIncludingCRLFGrapheme() {
        XCTAssertTrue(SegmentedTransfer.isSafeHeader(name: "X-Token", value: "abc"))
        XCTAssertFalse(SegmentedTransfer.isSafeHeader(name: "X-Token", value: "abc\r\nX-Evil: 1"))
        XCTAssertFalse(SegmentedTransfer.isSafeHeader(name: "X-Token", value: "abc\nX-Evil: 1"))
        XCTAssertFalse(SegmentedTransfer.isSafeHeader(name: "X:Bad", value: "v"))
        let req = SegmentedTransfer.makeRequest(
            URL(string: "https://example.test/f")!,
            settings: RequestSettings(userAgent: "UA", maxAttempts: 1, retryInterval: 0,
                                      extraHeaders: ["X-Evil": "a\r\nInjected: yes", "X-Ok": "fine"]))
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Evil"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Ok"), "fine")
    }

    // MARK: ENG-10 disk-full mapping

    func testDiskFullErrorsAreRecognisedAtAnyDepth() {
        XCTAssertNotNil(SegmentedTransfer.diskFullError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertNotNil(SegmentedTransfer.diskFullError(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))))
        XCTAssertNotNil(SegmentedTransfer.diskFullError(
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertNotNil(SegmentedTransfer.diskFullError(wrapped))
        XCTAssertNil(SegmentedTransfer.diskFullError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertNil(SegmentedTransfer.diskFullError(URLError(.timedOut)))
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ n: Int) { remaining = n }
    /// True while budget remains, consuming one.
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
