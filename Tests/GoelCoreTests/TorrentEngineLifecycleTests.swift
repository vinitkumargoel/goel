import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import GoelCore

/// `add` suspends on a remote .torrent fetch; whatever the user does meanwhile must win over the late handle.
final class TorrentEngineLifecycleTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-bt-life-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Holds the fetch until the test has acted, so the race is deterministic.
    private actor FetchGate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        private(set) var entered = false
        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func engine(gate: FetchGate, torrent: Data) -> TorrentEngine {
        TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false),
                      fetchTorrent: { _, _ in
                          await gate.wait()
                          return torrent
                      })
    }

    private func waitUntilEntered(_ gate: FetchGate) async throws {
        for _ in 0..<200 {
            if await gate.entered { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the engine never started fetching the .torrent")
    }

    private func remoteTask(name: String = "goel.bin") -> DownloadTask {
        DownloadTask(source: .torrentFile(URL(string: "https://example.com/\(UUID().uuidString).torrent")!),
                     name: name, saveDirectory: tempDir.appendingPathComponent("save").path)
    }

    func testRemoveDuringTorrentFetchLeavesNoZombie() async throws {
        let gate = FetchGate()
        let engine = engine(gate: gate, torrent: singleFileTorrent(payload: Data(repeating: 1, count: 16_384)))
        let task = remoteTask()

        let failed = Task { () -> Bool in
            for await event in engine.events(for: task.id) { if case .failed = event { return true } }
            return false
        }
        let adding = Task { await engine.add(task) }
        try await waitUntilEntered(gate)
        await engine.remove(task.id, deleteData: false)
        await gate.open()
        await adding.value

        let handles = await engine.handleCount
        let polling = await engine.isPolling(task.id)
        XCTAssertEqual(handles, 0, "a torrent added after its row was removed must not stay in the session")
        XCTAssertFalse(polling)
        let sawFailure = await failed.value
        XCTAssertFalse(sawFailure, "a removed task reports nothing")
    }

    func testTorrentFetchFailureCarriesTheHTTPStatus() async throws {
        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false),
                                   fetchTorrent: { _, _ in throw NetworkGuard.FetchError.httpStatus(404) })
        let task = remoteTask()
        let events = engine.events(for: task.id)   // subscribed before add, so nothing is missed
        let failure = Task { () -> String? in
            for await event in events {
                if case .failed(let error) = event { return "\(error)" }
            }
            return nil
        }
        await engine.add(task)
        let message = await failure.value
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("404") == true,
                      "the user must see why the .torrent could not be fetched, got: \(message ?? "nil")")
    }

    func testPauseDuringTorrentFetchKeepsTheTorrentPaused() async throws {
        let gate = FetchGate()
        let engine = engine(gate: gate, torrent: singleFileTorrent(payload: Data(repeating: 2, count: 16_384)))
        let task = remoteTask()

        let adding = Task { await engine.add(task) }
        try await waitUntilEntered(gate)
        await engine.pause(task.id)
        await gate.open()
        await adding.value

        let handles = await engine.handleCount
        let polling = await engine.isPolling(task.id)
        XCTAssertEqual(handles, 1, "the torrent is kept, ready to resume")
        XCTAssertFalse(polling, "but the pause that arrived mid-fetch must not be lost")

        await engine.resume(task.id)
        let resumed = await engine.isPolling(task.id)
        XCTAssertTrue(resumed)
        await engine.remove(task.id, deleteData: false)
    }

    func testResumeDuringTorrentFetchDoesNotStartASecondAdd() async throws {
        let gate = FetchGate()
        let engine = engine(gate: gate, torrent: singleFileTorrent(payload: Data(repeating: 3, count: 16_384)))
        let task = remoteTask()

        let adding = Task { await engine.add(task) }
        try await waitUntilEntered(gate)
        await engine.pause(task.id)
        await engine.resume(task.id)   // must not re-enter add() and fetch again
        await gate.open()
        await adding.value

        let handles = await engine.handleCount
        let polling = await engine.isPolling(task.id)
        XCTAssertEqual(handles, 1)
        XCTAssertTrue(polling, "the later resume cancels the earlier pause")
        await engine.remove(task.id, deleteData: false)
    }

    func testRefreshAppliesNewLimitsAndKeepsTheConsumedSkipList() async throws {
        let fixture = tempDir.appendingPathComponent("local.torrent")
        try singleFileTorrent(payload: Data(repeating: 4, count: 16_384)).write(to: fixture)
        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))
        var task = DownloadTask(source: .torrentFile(fixture), name: "goel.bin",
                                saveDirectory: tempDir.appendingPathComponent("save").path)
        await engine.add(task)

        task.name = "renamed.bin"
        task.speedLimitBytesPerSec = 64_000
        task.initialSkipFileIDs = [0]
        await engine.refresh(task)

        let stored = await engine.storedTask(task.id)
        XCTAssertEqual(stored?.name, "renamed.bin")
        XCTAssertEqual(stored?.speedLimitBytesPerSec, 64_000)
        XCTAssertNil(stored?.initialSkipFileIDs, "the one-shot skip list belongs to the engine once consumed")
        await engine.remove(task.id, deleteData: false)
    }

    func testRefreshOfAnUnknownTaskIsIgnored() async {
        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))
        let task = remoteTask()
        await engine.refresh(task)
        let stored = await engine.storedTask(task.id)
        XCTAssertNil(stored, "refresh must never resurrect a removed task")
    }

    func testShutdownSavesResumeDataAndReleasesTheSession() async throws {
        let saveDir = tempDir.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let payload = Data(repeating: 5, count: 16_384)
        try payload.write(to: saveDir.appendingPathComponent("goel.bin"))
        let fixture = tempDir.appendingPathComponent("local.torrent")
        try singleFileTorrent(payload: payload).write(to: fixture)

        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))
        let task = DownloadTask(source: .torrentFile(fixture), name: "goel.bin", saveDirectory: saveDir.path)
        await engine.add(task)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let blob = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("GoelDownloader/TorrentResume/\(task.id.uuidString).resume")
        addTeardownBlock { try? FileManager.default.removeItem(at: blob) }
        try? FileManager.default.removeItem(at: blob)

        await engine.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path), "quit must persist fast-resume data")
        let handles = await engine.handleCount
        let live = await engine.hasSession
        XCTAssertEqual(handles, 0)
        XCTAssertFalse(live, "the session is torn down, not left for deinit")
    }

    /// No announce list, deliberately: nothing in these tests may talk to a tracker.
    private func singleFileTorrent(payload: Data, name: String = "goel.bin") -> Data {
        var info = Data("d6:lengthi\(payload.count)e".utf8)
        info.append(Data("4:name\(name.utf8.count):\(name)".utf8))
        info.append(Data("12:piece lengthi\(payload.count)e".utf8))
        info.append(Data("6:pieces20:".utf8))
        info.append(Data(Insecure.SHA1.hash(data: payload)))
        info.append(Data("e".utf8))
        var torrent = Data("d4:info".utf8)
        torrent.append(info)
        torrent.append(Data("e".utf8))
        return torrent
    }
}
