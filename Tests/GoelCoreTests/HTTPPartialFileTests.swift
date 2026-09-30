import XCTest
@testable import GoelCore

/// ENG-11 / ENG-1 / ENG-17 / UX-1: in-progress bytes live in `<savePath>.goelpart` and only a verified
/// download takes the final name.
final class HTTPPartialFileTests: XCTestCase {

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

    private func makeEngine() -> HTTPEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return HTTPEngine(configuration: config, profile: .high, credentials: NoCredentials())
    }

    private struct NoCredentials: CredentialProviding {
        func basicAuthorization(forHost host: String) -> String? { nil }
    }

    /// HEAD advertises ranges; GETs are answered by `ranged`, defaulting to a correct 206.
    private func serve(_ payload: Data, etag: String = "\"p1\"",
                       ranged: (@Sendable (URLRequest) -> ScriptedURLProtocol.Reply?)? = nil) {
        ScriptedURLProtocol.script { req in
            if req.httpMethod == "HEAD" {
                return .init(status: 200, headers: ["Content-Length": "\(payload.count)",
                                                    "Accept-Ranges": "bytes", "ETag": etag], body: Data())
            }
            if let custom = ranged?(req) { return custom }
            let (a, b) = ScriptedURLProtocol.range(req, total: payload.count) ?? (0, payload.count - 1)
            return ScriptedURLProtocol.partial(payload, a, b, etag: etag)
        }
    }

    private func task(_ name: String, resume: Data? = nil, bytes: Int64 = 0) -> DownloadTask {
        var t = DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!),
                             name: name, saveDirectory: tempDir.path)
        t.resumeData = resume
        t.bytesDownloaded = bytes
        return t
    }

    private func runToEnd(_ engine: HTTPEngine, _ task: DownloadTask) async -> [EngineEvent] {
        let stream = engine.events(for: task.id)
        await engine.add(task)
        var events: [EngineEvent] = []
        for await event in stream {
            events.append(event)
            if case .statusChanged(.completed) = event { break }
            if case .failed = event { break }
        }
        return events
    }

    private func path(_ name: String) -> String { tempDir.appendingPathComponent(name).path }

    func testSuccessfulDownloadLandsAtFinalPathAndLeavesNoPartial() async throws {
        let payload = ScriptedURLProtocol.payload(300 * 1024)
        serve(payload)
        let events = await runToEnd(makeEngine(), task("done.bin"))
        XCTAssertTrue(events.contains(.statusChanged(.completed)))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("done.bin"))), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialFile.path(for: path("done.bin"))))
    }

    func testOverwriteKeepsTheExistingFileUntilTheNewOneSucceeds() async throws {
        let good = Data("the good copy".utf8)
        try good.write(to: URL(fileURLWithPath: path("movie.mkv")))
        let payload = ScriptedURLProtocol.payload(200 * 1024)
        serve(payload) { _ in .init(status: 403, headers: [:], body: Data()) }

        let engine = makeEngine()
        await engine.configureFileConflictPolicy("overwrite")
        let events = await runToEnd(engine, task("movie.mkv"))
        XCTAssertTrue(events.contains { if case .failed = $0 { return true }; return false })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("movie.mkv"))), good,
                       "a failed overwrite must leave the good file intact")

        serve(payload)
        let retry = makeEngine()
        await retry.configureFileConflictPolicy("overwrite")
        _ = await runToEnd(retry, task("movie.mkv"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("movie.mkv"))), payload,
                       "a successful overwrite replaces it atomically")
    }

    func testLegacyPartialAtFinalPathIsAdoptedAndResumed() async throws {
        let payload = ScriptedURLProtocol.payload(256 * 1024)
        let ranges = SegmentedTransfer.makeRanges(total: Int64(payload.count), count: 2)
        let firstLen = ranges[0].end - ranges[0].start + 1
        let cursor = SegmentedTransfer.ResumeCursor(
            etag: "\"p1\"", lastModified: nil, totalBytes: Int64(payload.count),
            ranges: ranges, completed: [firstLen, 0])
        // Pre-.goelpart builds wrote the preallocated partial under the final name.
        var legacy = payload.prefix(Int(firstLen))
        legacy.append(Data(count: payload.count - Int(firstLen)))
        try Data(legacy).write(to: URL(fileURLWithPath: path("legacy.bin")))

        serve(payload)
        let events = await runToEnd(makeEngine(), task("legacy.bin", resume: try JSONEncoder().encode(cursor),
                                                       bytes: firstLen))
        XCTAssertTrue(events.contains(.statusChanged(.completed)))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("legacy.bin"))), payload)
        let ranged = ScriptedURLProtocol.requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
        XCTAssertFalse(ranged.contains { $0.hasPrefix("bytes=0-") && $0 != "bytes=0-0" },
                       "the adopted first half must not be fetched again: \(ranged)")
    }

    func testRemovingAnUnfinishedTaskDeletesThePartialButNotAnExistingFinalFile() async throws {
        let existing = Data("user's own file".utf8)
        try existing.write(to: URL(fileURLWithPath: path("keep.bin")))
        try Data("partial".utf8).write(to: URL(fileURLWithPath: PartialFile.path(for: path("keep.bin"))))
        let hub = EventHub()
        HTTPEngine.removeDownloadedData(hub: hub, id: UUID(), task: task("keep.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialFile.path(for: path("keep.bin"))))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("keep.bin"))), existing)
    }

    func testRefreshAdoptsUserEditsAndMovesThePartialOnRename() async throws {
        let payload = ScriptedURLProtocol.payload(64 * 1024)
        // Never answer the body, so the task sits paused with its partial on disk.
        serve(payload) { _ in .init(status: 503, headers: ["Retry-After": "15"], body: Data()) }
        let engine = makeEngine()
        var original = task("old.bin")
        original.speedLimitBytesPerSec = nil
        await engine.add(original)
        try await Task.sleep(nanoseconds: 200_000_000)
        await engine.pause(original.id)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: PartialFile.path(for: path("old.bin"))))

        var renamed = original
        renamed.name = "new.bin"
        renamed.speedLimitBytesPerSec = 1234
        await engine.refresh(renamed)

        let stored = await engine.tasks[original.id]
        XCTAssertEqual(stored?.name, "new.bin")
        XCTAssertEqual(stored?.speedLimitBytesPerSec, 1234)
        XCTAssertEqual(stored?.status, .paused, "status stays engine-owned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: PartialFile.path(for: path("new.bin"))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialFile.path(for: path("old.bin"))))
        await engine.remove(original.id, deleteData: false)
    }

    func testRefreshKeepsANewerStreamedCursor() async throws {
        let engine = makeEngine()
        serve(ScriptedURLProtocol.payload(1024)) { _ in .init(status: 503, headers: ["Retry-After": "15"], body: Data()) }
        let t = task("cursor.bin", resume: Data("old".utf8), bytes: 10)
        await engine.add(t)
        await engine.pause(t.id)
        await engine.refresh(t)
        let kept = await engine.tasks[t.id]?.resumeData
        XCTAssertEqual(kept, Data("old".utf8), "no streamed cursor yet: the manager's copy stands")

        var restart = t
        restart.resumeData = nil
        restart.bytesDownloaded = 0
        await engine.refresh(restart)
        let cleared = await engine.tasks[t.id]?.resumeData
        XCTAssertNil(cleared, "a deliberate restart (no cursor, no bytes) is honoured")
        await engine.remove(t.id, deleteData: false)
    }

    func testProbeFailureCarriesTheReason() async {
        ScriptedURLProtocol.script { _ in .init(status: 403, headers: [:], body: Data()) }
        let meta = await makeEngine().resolveMetadata(for: URL(string: "https://example.test/x")!,
                                                      currentName: "x")
        XCTAssertFalse(meta.reachable)
        XCTAssertEqual(meta.failureNote, "The server refused access (HTTP 403)")
    }
}
