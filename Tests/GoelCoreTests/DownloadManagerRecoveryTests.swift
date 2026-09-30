import XCTest
@testable import GoelCore

final class DownloadManagerRecoveryTests: XCTestCase {

    private var saveDir: String!

    override func setUpWithError() throws {
        saveDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("goel-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: saveDir)
    }

    private func makeManager(_ http: FakeEngine) -> DownloadManager {
        DownloadManager(
            httpEngine: http,
            torrentEngine: FakeEngine(kind: .torrent),
            settings: AppSettings(profiles: TrafficProfile.defaults,
                                  selectedProfileName: TrafficProfile.high.name,
                                  speedLimitEnabled: false,
                                  defaultSaveDirectory: saveDir))
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    /// Adds a download and drives it to `.failed(error)`.
    private func failedTask(_ manager: DownloadManager, _ http: FakeEngine,
                            url: String = "https://example.test/file.bin",
                            error: DownloadError = .httpStatus(404),
                            resumeData: Data? = nil) async -> DownloadTask {
        let task = await manager.add(source: .url(URL(string: url)!), saveDirectory: saveDir)
        _ = await waitUntil { http.added.contains(task.id) }
        if let resumeData {
            http.emit(.resumeDataUpdated(resumeData), for: task.id)
            _ = await waitUntil { await manager.task(task.id)?.resumeData != nil }
        }
        http.emit(.failed(error), for: task.id)
        _ = await waitUntil { await manager.task(task.id)?.status.isFailed == true }
        return await manager.task(task.id)!
    }

    // MARK: - replaceSource

    func testReplacingTheLinkOfAFailedDownloadRetriesItAtTheNewAddress() async {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await failedTask(manager, http)

        let result = await manager.replaceSource(task.id, with: "  https://cdn.example.test/fresh.bin?sig=1 ")
        XCTAssertEqual(result, .replaced(keepsPartial: false))
        let updated = await manager.task(task.id)
        XCTAssertEqual(updated?.source.locator, "https://cdn.example.test/fresh.bin?sig=1")
        XCTAssertEqual(updated?.name, task.name, "the file name (and so the partial) stays the same")
        let revived = await waitUntil { http.resumed.contains(task.id) }
        XCTAssertTrue(revived, "a failed download goes back in line after its link is replaced")
    }

    func testReplacingTheLinkKeepsTheResumeCursorForTheEngineToValidate() async {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await failedTask(manager, http, resumeData: Data("cursor".utf8))

        let result = await manager.replaceSource(task.id, with: "https://mirror.example.test/file.bin")
        XCTAssertEqual(result, .replaced(keepsPartial: true))
        let resume = await manager.task(task.id)?.resumeData
        XCTAssertEqual(resume, Data("cursor".utf8))
    }

    func testReplacingRejectsBadLinks() async {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await failedTask(manager, http)

        let notALink = await manager.replaceSource(task.id, with: "not a link")
        XCTAssertEqual(notALink, .invalidLink)
        let magnet = await manager.replaceSource(task.id, with: "magnet:?xt=urn:btih:abcdef")
        XCTAssertEqual(magnet, .invalidLink)
        let same = await manager.replaceSource(task.id, with: "https://example.test/file.bin")
        XCTAssertEqual(same, .sameLink)
        let missing = await manager.replaceSource(UUID(), with: "https://example.test/x.bin")
        XCTAssertEqual(missing, .notFound)

    }

    func testReplacingWithAnotherDownloadsLinkIsRefused() async {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await failedTask(manager, http)
        let other = await manager.add(source: .url(URL(string: "https://example.test/other.bin")!),
                                      startPaused: true)

        let result = await manager.replaceSource(task.id, with: "https://example.test/other.bin")
        XCTAssertEqual(result, .duplicate(name: other.name))
    }

    // MARK: - relocate

    func testRelocatingAFailedDownloadMovesItsPartialAndRetries() async throws {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await failedTask(manager, http, error: .diskFull(needed: 10, available: 1))
        let part = PartialFile.path(for: task.savePath)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: part))
        let target = (saveDir as NSString).appendingPathComponent("elsewhere")

        let result = await manager.relocate(task.id, to: target)
        XCTAssertEqual(result, .moved)
        let moved = (target as NSString).appendingPathComponent((part as NSString).lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part))
        let updated = await manager.task(task.id)
        XCTAssertEqual(updated?.saveDirectory, target)
        let revived = await waitUntil { http.resumed.contains(task.id) }
        XCTAssertTrue(revived)
    }

    func testRelocatingRefusesToOverwriteAFileAlreadyThere() async throws {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await failedTask(manager, http)
        let part = PartialFile.path(for: task.savePath)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: part))
        let target = (saveDir as NSString).appendingPathComponent("taken")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        let clash = (target as NSString).appendingPathComponent((part as NSString).lastPathComponent)
        try Data("someone else".utf8).write(to: URL(fileURLWithPath: clash))

        let result = await manager.relocate(task.id, to: target)
        XCTAssertEqual(result, .conflict)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part), "the original partial is untouched")
        let dir = await manager.task(task.id)?.saveDirectory
        XCTAssertEqual(dir, saveDir)
    }

    func testRelocatingToTheSameFolderIsANoOp() async {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await failedTask(manager, http)
        let result = await manager.relocate(task.id, to: saveDir + "/")
        XCTAssertEqual(result, .sameFolder)
    }

    // MARK: - retry(at:)

    func testRetryLaterParksTheDownloadWithAScheduledStart() async {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await failedTask(manager, http, error: .httpStatus(429))
        let when = Date().addingTimeInterval(300)

        let parked = await manager.retry(task.id, at: when)
        XCTAssertTrue(parked)
        let updated = await manager.task(task.id)
        XCTAssertEqual(updated?.status, .paused)
        XCTAssertEqual(updated?.scheduledAt, when)
    }

    func testRetryLaterIgnoresADownloadThatIsNotFailed() async {
        let http = FakeEngine(kind: .http)
        let manager = makeManager(http)
        let task = await manager.add(source: .url(URL(string: "https://example.test/p.bin")!),
                                     startPaused: true)
        let parked = await manager.retry(task.id, at: Date().addingTimeInterval(60))
        XCTAssertFalse(parked)
        let scheduled = await manager.task(task.id)?.scheduledAt
        XCTAssertNil(scheduled)
    }
}
