import XCTest
@testable import GoelCore

/// engines#1/#2/#5/#7, integration#4/#12, silent#16: entity validation that tolerates load-balanced
/// ETags, CR-less 206s, `.goelpart` collisions and a final path that must not be clobbered.
final class HTTPEntityAndNamingTests: XCTestCase {

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

    private let lastModified = "Wed, 01 Jan 2025 00:00:00 GMT"

    private func plan(_ name: String, total: Int, segments: Int, lastModified: String?,
                      maxAttempts: Int = 3) -> TransferPlan {
        TransferPlan(
            url: URL(string: "https://example.test/\(name)")!,
            destination: tempDir.appendingPathComponent(name),
            totalBytes: Int64(total), acceptsRanges: true,
            etag: "\"node-a\"", lastModified: lastModified, existingResume: nil,
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

    private func partial(_ payload: Data, _ a: Int, _ b: Int, etag: String, lastModified: String?)
        -> ScriptedURLProtocol.Reply {
        var reply = ScriptedURLProtocol.partial(payload, a, b, etag: etag)
        reply.headers["Last-Modified"] = lastModified
        return reply
    }

    // MARK: engines#2 — ETag strictness

    func testDifferentETagWithMatchingLastModifiedIsTheSameEntity() async throws {
        let payload = ScriptedURLProtocol.payload(256 * 1024)
        let lm = lastModified
        ScriptedURLProtocol.script { req in
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            return self.partial(payload, a, b, etag: "\"node-b\"", lastModified: lm)
        }
        _ = try await run(plan("lb.bin", total: payload.count, segments: 4, lastModified: lm))
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("lb.bin")), payload)
    }

    func testDifferentETagAndDifferentLastModifiedIsAChange() async throws {
        let payload = ScriptedURLProtocol.payload(128 * 1024)
        ScriptedURLProtocol.script { req in
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            return self.partial(payload, a, b, etag: "\"node-b\"", lastModified: "Thu, 02 Jan 2025 00:00:00 GMT")
        }
        do {
            _ = try await run(plan("edited.bin", total: payload.count, segments: 2,
                                   lastModified: lastModified, maxAttempts: 2))
            XCTFail("a changed entity must not complete")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .remoteFileChanged)
        }
    }

    func testIfRange200OfTheSameSizeAndDateIsRetriedWithoutIfRange() async throws {
        let payload = ScriptedURLProtocol.payload(256 * 1024)
        let lm = lastModified
        // Another node: its ETag differs, so it answers our If-Range with the (identical) whole file.
        ScriptedURLProtocol.script { req in
            if req.value(forHTTPHeaderField: "If-Range") != nil {
                return .init(status: 200, headers: ["ETag": "\"node-b\"", "Last-Modified": lm,
                                                    "Content-Length": "\(payload.count)"], body: payload)
            }
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            return self.partial(payload, a, b, etag: "\"node-b\"", lastModified: lm)
        }
        _ = try await run(plan("ifrange-lb.bin", total: payload.count, segments: 2, lastModified: lm))
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("ifrange-lb.bin")), payload)
    }

    func testIfRange200WithAnotherSizeIsStillAChange() async throws {
        let payload = ScriptedURLProtocol.payload(128 * 1024)
        let lm = lastModified
        ScriptedURLProtocol.script { _ in
            .init(status: 200, headers: ["ETag": "\"v2\"", "Last-Modified": lm,
                                         "Content-Length": "\(payload.count + 1)"], body: payload + Data([0]))
        }
        do {
            _ = try await run(plan("grown.bin", total: payload.count, segments: 2, lastModified: lm, maxAttempts: 2))
            XCTFail("a different body must not complete")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .remoteFileChanged)
        }
    }

    // MARK: engines#5 — 206 without Content-Range

    func testPartialWithoutContentRangeIsTakenAsTheRequestedRange() async throws {
        let payload = ScriptedURLProtocol.payload(256 * 1024)
        ScriptedURLProtocol.script { req in
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count)!
            return .init(status: 206, headers: ["Content-Length": "\(b - a + 1)", "ETag": "\"node-a\""],
                         body: payload.subdata(in: a..<(b + 1)))
        }
        _ = try await run(plan("nocr.bin", total: payload.count, segments: 4, lastModified: nil))
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("nocr.bin")), payload)
    }

    func testImpliedRangeRefusesAWrongLengthOrMultipart() {
        let url = URL(string: "https://example.test/x")!
        let wrong = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Length": "5"])!
        XCTAssertNil(SegmentedTransfer.impliedRange(wrong, start: 0, end: 9))
        let multi = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "multipart/byteranges; boundary=x"])!
        XCTAssertNil(SegmentedTransfer.impliedRange(multi, start: 0, end: 9))
        let fine = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Length": "10"])!
        XCTAssertEqual(SegmentedTransfer.impliedRange(fine, start: 0, end: 9)?.end, 9)
    }

    // MARK: engines#7 — reservation covers the file

    func testPreallocateReservesTheWholeFile() throws {
        let url = tempDir.appendingPathComponent("reserve.bin")
        let size: Int64 = 8 * 1024 * 1024
        try SegmentedTransfer.preallocate(url, size: size)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.int64Value, size)
        #if canImport(Darwin)
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0)
        XCTAssertGreaterThanOrEqual(Int64(st.st_blocks) * 512, size, "blocks must back [0, size), not sit past EOF")
        #endif
    }

    // MARK: engines#1 / silent#16 — finalize never clobbers under "rename"

    func testFinalizeUnderRenameStepsOverAFileThatAppearedMidTransfer() throws {
        let final = tempDir.appendingPathComponent("movie.mkv")
        let part = URL(fileURLWithPath: PartialFile.path(for: final.path))
        try Data("user's".utf8).write(to: final)
        try Data("download".utf8).write(to: part)
        let placed = try HTTPEngine.finalizePartial(part, to: final, overwrite: false)
        XCTAssertEqual(placed.lastPathComponent, "movie (1).mkv")
        XCTAssertEqual(try Data(contentsOf: final), Data("user's".utf8), "the existing file is untouched")
        XCTAssertEqual(try Data(contentsOf: placed), Data("download".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testFinalizeUnderOverwriteReplaces() throws {
        let final = tempDir.appendingPathComponent("movie.mkv")
        let part = URL(fileURLWithPath: PartialFile.path(for: final.path))
        try Data("old".utf8).write(to: final)
        try Data("new".utf8).write(to: part)
        let placed = try HTTPEngine.finalizePartial(part, to: final, overwrite: true)
        XCTAssertEqual(placed, final)
        XCTAssertEqual(try Data(contentsOf: final), Data("new".utf8))
    }

    // MARK: engines#1 / integration#12 — live-task collisions on first attempt

    private struct NoCredentials: CredentialProviding {
        func basicAuthorization(forHost host: String) -> String? { nil }
    }

    private func engine() -> HTTPEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return HTTPEngine(configuration: config, profile: .high, credentials: NoCredentials())
    }

    private func serveHeadThenWait(_ size: Int) {
        ScriptedURLProtocol.script { req in
            if req.httpMethod == "HEAD" {
                return .init(status: 200, headers: ["Content-Length": "\(size)", "Accept-Ranges": "bytes",
                                                    "ETag": "\"p\""], body: Data())
            }
            return .init(status: 503, headers: ["Retry-After": "15"], body: Data())
        }
    }

    private func task(_ name: String, path: String = "file.zip") -> DownloadTask {
        DownloadTask(source: .url(URL(string: "https://example.test/\(path)")!), name: name,
                     saveDirectory: tempDir.path)
    }

    private func settledName(_ engine: HTTPEngine, _ id: UUID, not original: String? = nil) async throws -> String? {
        for _ in 0..<100 {
            if let name = await engine.tasks[id]?.name, name != original { return name }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return await engine.tasks[id]?.name
    }

    func testTwoQueuedTasksWithOneNameNeverShareAPartial() async throws {
        serveHeadThenWait(1024)
        let engine = engine()
        let first = task("file.zip")
        let second = task("file.zip")
        await engine.add(first)
        try await Task.sleep(nanoseconds: 200_000_000)
        await engine.add(second)
        let renamed = try await settledName(engine, second.id, not: "file.zip")
        XCTAssertEqual(renamed, "file (1).zip")
        let kept = await engine.tasks[first.id]?.name
        XCTAssertEqual(kept, "file.zip")
        await engine.remove(first.id, deleteData: false)
        await engine.remove(second.id, deleteData: false)
    }

    func testRenamePolicyStepsOverAFinalFileThatAppearedBeforeTheFirstRun() async throws {
        serveHeadThenWait(1024)
        try Data("mine".utf8).write(to: tempDir.appendingPathComponent("file.zip"))
        let engine = engine()
        let t = task("file.zip")
        await engine.add(t)
        let renamed = try await settledName(engine, t.id, not: "file.zip")
        XCTAssertEqual(renamed, "file (1).zip")
        await engine.remove(t.id, deleteData: false)
    }

    func testOverwritePolicyIgnoresCompletedTasksAndExistingFiles() async throws {
        let payload = ScriptedURLProtocol.payload(64 * 1024)
        ScriptedURLProtocol.script { req in
            if req.httpMethod == "HEAD" {
                return .init(status: 200, headers: ["Content-Length": "\(payload.count)",
                                                    "Accept-Ranges": "bytes", "ETag": "\"p\""], body: Data())
            }
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count) ?? (0, payload.count - 1)
            return ScriptedURLProtocol.partial(payload, a, b, etag: "\"p\"")
        }
        let engine = engine()
        await engine.configureFileConflictPolicy("overwrite")
        let done = task("file.zip")
        let events = engine.events(for: done.id)
        await engine.add(done)
        for await event in events { if case .statusChanged(.completed) = event { break } }

        let again = task("file.zip")
        let againEvents = engine.events(for: again.id)
        await engine.add(again)
        var renamedTo: String?
        for await event in againEvents {
            if case .nameResolved(let name) = event { renamedTo = name }
            if case .statusChanged(.completed) = event { break }
            if case .failed = event { break }
        }
        XCTAssertNil(renamedTo, "a completed row owns no partial, and overwrite means the same name")
        let name = await engine.tasks[again.id]?.name
        XCTAssertEqual(name, "file.zip")
    }

    // MARK: integration#4 — Keychain lookup host

    private final class RecordingCredentials: CredentialProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String] = []
        var seen: [String] { lock.lock(); defer { lock.unlock() }; return hosts }
        func basicAuthorization(forHost host: String) -> String? {
            lock.lock(); hosts.append(host); lock.unlock()
            return host == "files.example.test" ? "Basic eDp5" : nil
        }
    }

    func testCredentialLookupUsesTheLowercasedHost() {
        let creds = RecordingCredentials()
        let engine = HTTPEngine(configuration: .ephemeral, credentials: creds)
        let req = engine.makeRequest(URL(string: "https://Files.Example.TEST/a.iso")!, userAgent: "UA")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Basic eDp5")
        XCTAssertEqual(creds.seen, ["files.example.test"])
    }
}
