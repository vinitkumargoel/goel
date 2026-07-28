import XCTest
@testable import GoelCore

final class MockTorrentEngineTests: XCTestCase {

    private let mb: Int64 = 1024 * 1024

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

    private func fastSim(
        uploadBytesPerTick: Int64 = 700 * 1024 * 1024,
        metadataDelayTicks: Int = 2
    ) -> MockTorrentEngine.Simulation {
        MockTorrentEngine.Simulation(
            tickInterval: 0.002,
            bytesPerTick: 1_000_000_000,
            uploadBytesPerTick: uploadBytesPerTick,
            metadataDelayTicks: metadataDelayTicks,
            minPeers: 2,
            maxPeers: 40
        )
    }

    private func magnetTask() -> DownloadTask {
        DownloadTask(
            source: .magnet("magnet:?xt=urn:btih:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"),
            name: "Demo.Pack",
            saveDirectory: tempDir.path
        )
    }

    private func drain(
        _ engine: MockTorrentEngine,
        _ task: DownloadTask,
        until isDone: @escaping @Sendable (EngineEvent) -> Bool,
        timeout: TimeInterval = 10
    ) async -> [EngineEvent] {
        let stream = engine.events(for: task.id)
        await engine.add(task)
        return await collect(stream, until: isDone, timeout: timeout)
    }

    private func collect(
        _ stream: AsyncStream<EngineEvent>,
        until isDone: @escaping @Sendable (EngineEvent) -> Bool,
        timeout: TimeInterval
    ) async -> [EngineEvent] {
        await withTaskGroup(of: [EngineEvent]?.self) { group in
            group.addTask {
                var collected: [EngineEvent] = []
                for await event in stream {
                    collected.append(event)
                    if isDone(event) { return collected }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? []
        }
    }

    private func isStatus(_ event: EngineEvent, _ status: DownloadStatus) -> Bool {
        if case .statusChanged(let s) = event { return s == status }
        return false
    }

    func testMagnetResolvesMetadataThenDownloads() async throws {
        let engine = MockTorrentEngine(simulation: fastSim(), profile: .high)
        let task = magnetTask()

        let events = await drain(engine, task) { self.isStatus($0, .downloading) }

        let reqIndex = events.firstIndex { self.isStatus($0, .requestingMetadata) }
        let dlIndex = events.firstIndex { self.isStatus($0, .downloading) }
        XCTAssertNotNil(reqIndex, "magnet must enter .requestingMetadata first")
        XCTAssertNotNil(dlIndex, "magnet must reach .downloading")
        if let r = reqIndex, let d = dlIndex {
            XCTAssertLessThan(r, d, "requestingMetadata must precede downloading")
        }

        var resolvedFiles: [TransferFile] = []
        var resolvedTotal: Int64 = 0
        for event in events {
            if case .metadataResolved(_, let total, let files) = event {
                resolvedFiles = files
                resolvedTotal = total
            }
        }
        XCTAssertGreaterThan(resolvedFiles.count, 1, "metadata must resolve to a MULTI-file list")
        XCTAssertGreaterThan(resolvedTotal, 0, "resolved total size must be positive")
        XCTAssertEqual(resolvedTotal, resolvedFiles.reduce(0) { $0 + $1.length })

        await engine.remove(task.id, deleteData: true)
    }

    func testReachesSeedingWithUploads() async throws {
        let engine = MockTorrentEngine(simulation: fastSim(), profile: .high)
        let task = magnetTask()

        let events = await drain(engine, task) { self.isStatus($0, .seeding) }

        let sawFinished = events.contains { if case .finished = $0 { return true }; return false }
        XCTAssertTrue(sawFinished, "must emit .finished before seeding")
        XCTAssertTrue(events.contains { self.isStatus($0, .seeding) }, "must transition to .seeding")
        XCTAssertFalse(
            events.contains { self.isStatus($0, .completed) },
            "must NOT go straight to .completed — torrents seed first"
        )

        let snap = await engine.snapshot(task.id)
        XCTAssertNotNil(snap?.totalBytes)
        XCTAssertEqual(snap?.bytesDownloaded, snap?.totalBytes, "download must reach 100%")
        XCTAssertGreaterThan(snap?.bytesUploaded ?? 0, 0, "seeding implies upload activity")
        XCTAssertEqual(snap?.status, .seeding)

        await engine.remove(task.id, deleteData: true)
    }

    func testSeedingStopsAtRatioLimitThenCompletes() async throws {
        let limit = 1.0
        let profile = TrafficProfile(
            name: "Test",
            maxDownloadBytesPerSec: 0,
            maxUploadBytesPerSec: 0,
            maxConnections: 0,
            maxConnectionsPerServer: 0,
            maxSimultaneousDownloads: 0,
            maxMetadataResolutions: 0,
            seedRatioLimit: limit,
            enableExtraConnections: false
        )
        let engine = MockTorrentEngine(simulation: fastSim(uploadBytesPerTick: 200 * mb))
        await engine.applyLimits(profile)

        let task = magnetTask()
        let events = await drain(engine, task) { self.isStatus($0, .completed) }

        let finishedIdx = events.firstIndex { if case .finished = $0 { return true }; return false }
        let seedingIdx = events.firstIndex { self.isStatus($0, .seeding) }
        let completedIdx = events.firstIndex { self.isStatus($0, .completed) }
        XCTAssertNotNil(finishedIdx)
        XCTAssertNotNil(seedingIdx)
        XCTAssertNotNil(completedIdx)
        if let f = finishedIdx, let s = seedingIdx, let c = completedIdx {
            XCTAssertLessThan(f, s)
            XCTAssertLessThan(s, c)
        }

        let snap = await engine.snapshot(task.id)
        XCTAssertEqual(snap?.status, .completed)
        XCTAssertNotNil(snap?.completedAt)
        XCTAssertGreaterThanOrEqual(snap?.shareRatio ?? 0, limit, "must seed until the ratio limit")

        await engine.remove(task.id, deleteData: true)
    }

    func testSkipDeselectsFileAndReducesWork() async throws {
        let profile = TrafficProfile(
            name: "NoSeed",
            maxDownloadBytesPerSec: 0,
            maxUploadBytesPerSec: 0,
            maxConnections: 0,
            maxConnectionsPerServer: 0,
            maxSimultaneousDownloads: 0,
            maxMetadataResolutions: 0,
            seedRatioLimit: 0,
            enableExtraConnections: false
        )
        // Moderate tick so the skip lands before the skipped file's turn to download.
        let sim = MockTorrentEngine.Simulation(
            tickInterval: 0.01,
            bytesPerTick: 1 * mb,
            uploadBytesPerTick: 0,
            metadataDelayTicks: 0,
            minPeers: 1,
            maxPeers: 5
        )
        let engine = MockTorrentEngine(simulation: sim, profile: profile)

        let files = [
            TransferFile(id: 0, path: "pack/a.bin", length: 1 * mb),
            TransferFile(id: 1, path: "pack/b.bin", length: 2 * mb),
            TransferFile(id: 2, path: "pack/c.bin", length: 3 * mb),
            TransferFile(id: 3, path: "pack/d.bin", length: 4 * mb),
        ]
        let total = files.reduce(0) { $0 + $1.length }
        let skippedID = 3
        let skippedLength = files[skippedID].length
        let task = DownloadTask(
            source: .torrentFile(URL(string: "file://\(tempDir.path)/pack.torrent")!),
            name: "pack",
            saveDirectory: tempDir.path,
            totalBytes: total,
            files: files
        )

        let stream = engine.events(for: task.id)
        await engine.add(task)
        await engine.setFilePriority(.skip, fileID: skippedID, task: task.id)

        let events = await collect(stream, until: { self.isStatus($0, .completed) }, timeout: 10)

        let progressedSkipped = events.contains {
            if case .fileProgress(let fid, _) = $0 { return fid == skippedID }
            return false
        }
        XCTAssertFalse(progressedSkipped, "a skipped file must not download")

        let snap = await engine.snapshot(task.id)
        let skippedFile = snap?.files.first { $0.id == skippedID }
        XCTAssertEqual(skippedFile?.priority, .skip)
        XCTAssertEqual(skippedFile?.isWanted, false)
        XCTAssertEqual(skippedFile?.bytesCompleted, 0, "skipped file gets no bytes")
        XCTAssertEqual(snap?.wantedFiles.count, files.count - 1)
        XCTAssertEqual(
            snap?.bytesDownloaded,
            total - skippedLength,
            "effective work must shrink by the skipped file's size"
        )
        XCTAssertEqual(snap?.status, .completed)

        await engine.remove(task.id, deleteData: true)
    }
}
