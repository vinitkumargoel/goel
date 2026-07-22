import XCTest
@testable import GoelCore

/// The feature gate, the reconcile fix, and the admission rules for sending a download to an SFTP server.
///
/// Nothing here contacts a server: the guarantees worth testing are the ones that hold *before* a session opens, which is exactly where a bug would be destructive.
final class RemoteDestinationTests: XCTestCase {

    private var tempDirs: [String] = []

    private func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-remote-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(atPath: dir) }
        tempDirs.removeAll()
    }

    private func destination(directory: String = "/srv/media",
                             removeLocal: Bool = false,
                             state: RemoteUploadState = .pending) -> RemoteDestination {
        RemoteDestination(connectionID: UUID(), serverLabel: "media-box",
                          directory: directory, removeLocalAfterUpload: removeLocal, state: state)
    }

    private func manager(enabled: Bool) -> DownloadManager {
        var settings = AppSettings()
        settings.sftpDestinationEnabled = enabled
        return DownloadManager(httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
                               settings: settings)
    }

    // MARK: The flag

    func testDefaultsToOff() {
        XCTAssertFalse(AppSettings().sftpDestinationEnabled)
    }

    /// The point of `decodeIfPresent` throughout: a settings blob written before this key existed must load, not throw.
    func testSettingsBlobWrittenBeforeTheKeyExistedStillDecodes() throws {
        let legacy = Data(#"{"theme":"frost-dark","backupKeepCount":7}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertFalse(decoded.sftpDestinationEnabled)
        XCTAssertEqual(decoded.backupKeepCount, 7)
        XCTAssertEqual(decoded.sftpDestinationMaxConcurrentUploads, 4)
    }

    func testFlagSurvivesARoundTrip() throws {
        var settings = AppSettings()
        settings.sftpDestinationEnabled = true
        settings.sftpDestinationStagingBudgetGB = 12
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.sftpDestinationEnabled)
        XCTAssertEqual(decoded.sftpDestinationStagingBudgetGB, 12)
    }

    /// With the feature off, `add` must behave exactly as if it did not exist — a destination passed in is dropped, not honoured later.
    func testAddDropsTheDestinationWhenTheFeatureIsOff() async {
        let manager = self.manager(enabled: false)
        let task = await manager.add(source: DownloadSource.parse("https://example.com/a.bin")!,
                                     saveDirectory: makeTempDir(),
                                     remoteDestination: destination())
        XCTAssertNil(task.remoteDestination)
    }

    func testAddKeepsTheDestinationWhenTheFeatureIsOn() async {
        let manager = self.manager(enabled: true)
        let task = await manager.add(source: DownloadSource.parse("https://example.com/b.bin")!,
                                     saveDirectory: makeTempDir(),
                                     remoteDestination: destination())
        XCTAssertEqual(task.remoteDestination?.directory, "/srv/media")
        XCTAssertEqual(task.remoteDestination?.state, .pending)
    }

    /// A backup file must never be able to switch on a feature that sends the user's files to another machine.
    func testImportedSettingsCannotEnableTheFeature() {
        var imported = AppSettings(); imported.sftpDestinationEnabled = true
        let current = AppSettings()                       // off
        let safe = DownloadManager.sanitizedImportedSettings(imported, current: current)
        XCTAssertFalse(safe.sftpDestinationEnabled)
    }

    /// "Send to server" is refused outright while the feature is off — no session, no Keychain read, nothing sent.
    func testSendToServerIsRefusedWhenTheFeatureIsOff() async {
        let manager = self.manager(enabled: false)
        let dir = makeTempDir()
        let task = await manager.add(source: DownloadSource.parse("https://example.com/c.bin")!,
                                     saveDirectory: dir)
        let accepted = await manager.sendToServer(task.id, destination: destination())
        XCTAssertFalse(accepted)
        let after = await manager.task(task.id)
        XCTAssertNil(after?.remoteDestination)
    }

    // MARK: The reconcile sweep

    private func completedTask(name: String, in directory: String,
                               destination: RemoteDestination?) -> DownloadTask {
        DownloadTask(source: DownloadSource.parse("https://example.com/\(name)")!,
                     name: name, saveDirectory: directory, totalBytes: 1, bytesDownloaded: 1,
                     status: .completed, completedAt: Date(), remoteDestination: destination)
    }

    /// The regression this feature would otherwise ship: a payload uploaded and then cleaned up locally looks exactly like a Finder delete, so the row vanished within five seconds of succeeding.
    func testUploadedAndCleanedUpTaskSurvivesTheSweep() {
        let dir = makeTempDir()                                  // directory exists, file deliberately gone
        let task = completedTask(name: "sent.bin", in: dir,
                                 destination: destination(removeLocal: true, state: .uploaded))
        XCTAssertFalse(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    /// An upload in flight is reading that file right now; a pending one still needs it.
    func testTaskAwaitingOrDuringUploadSurvivesTheSweep() {
        let dir = makeTempDir()
        for state in [RemoteUploadState.pending, .uploading] {
            let task = completedTask(name: "waiting.bin", in: dir,
                                     destination: destination(removeLocal: true, state: state))
            XCTAssertFalse(DownloadManager.completedPayloadIsMissing(task, fileManager: .default),
                           "state \(state)")
        }
    }

    /// The sweep must not become a blanket exemption: a server-bound task that failed, and whose file the user then deleted, is still gone.
    func testFailedUploadWhoseFileTheUserDeletedIsStillPruned() {
        let dir = makeTempDir()
        let task = completedTask(name: "failed.bin", in: dir,
                                 destination: destination(removeLocal: true, state: .failed))
        XCTAssertTrue(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    /// Keeping the local copy is the default, so an uploaded-but-kept payload that then disappears really was deleted by the user.
    func testUploadedButKeptLocallyIsPrunedWhenTheFileGoes() {
        let dir = makeTempDir()
        let task = completedTask(name: "kept.bin", in: dir,
                                 destination: destination(removeLocal: false, state: .uploaded))
        XCTAssertTrue(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    func testOrdinaryLocalDownloadsAreUnaffected() {
        let dir = makeTempDir()
        let path = (dir as NSString).appendingPathComponent("local.bin")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let present = completedTask(name: "local.bin", in: dir, destination: nil)
        XCTAssertFalse(DownloadManager.completedPayloadIsMissing(present, fileManager: .default))
        let absent = completedTask(name: "vanished.bin", in: dir, destination: nil)
        XCTAssertTrue(DownloadManager.completedPayloadIsMissing(absent, fileManager: .default))
    }

    // MARK: Model invariants

    func testLocalRemovalIsOnlyExpectedAfterAVerifiedUpload() {
        XCTAssertTrue(destination(removeLocal: true, state: .uploaded).localCopyIntentionallyRemoved)
        XCTAssertFalse(destination(removeLocal: true, state: .uploading).localCopyIntentionallyRemoved)
        XCTAssertFalse(destination(removeLocal: false, state: .uploaded).localCopyIntentionallyRemoved)
    }

    func testDestinationBlobWithOnlyAConnectionIDStillDecodes() throws {
        let id = UUID()
        let sparse = Data(#"{"connectionID":"\#(id.uuidString)"}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteDestination.self, from: sparse)
        XCTAssertEqual(decoded.connectionID, id)
        XCTAssertEqual(decoded.directory, ".")
        XCTAssertEqual(decoded.state, .pending)
        XCTAssertFalse(decoded.removeLocalAfterUpload)
        XCTAssertFalse(decoded.token.isEmpty)
    }

    /// A task persisted before this feature existed must decode with no destination rather than throwing.
    func testTaskBlobWithoutADestinationDecodes() throws {
        let task = DownloadTask(source: DownloadSource.parse("https://example.com/x.bin")!,
                                name: "x.bin", saveDirectory: "/tmp")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "remoteDestination")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: data)
        XCTAssertNil(decoded.remoteDestination)
    }

    func testRemoteOnlyRequiresBothCompletionAndCleanup() {
        let uploaded = DownloadTask(source: DownloadSource.parse("https://example.com/y.bin")!,
                                    name: "y.bin", saveDirectory: "/tmp", status: .completed,
                                    remoteDestination: destination(removeLocal: true, state: .uploaded))
        XCTAssertTrue(uploaded.isRemoteOnly)

        let stillGoing = DownloadTask(source: DownloadSource.parse("https://example.com/z.bin")!,
                                      name: "z.bin", saveDirectory: "/tmp", status: .completed,
                                      remoteDestination: destination(removeLocal: true, state: .uploading))
        XCTAssertFalse(stillGoing.isRemoteOnly)
        XCTAssertTrue(stillGoing.isUploadingToRemote)
    }

    func testConnectionUploadPathCascades() {
        var connection = SFTPConnection(name: "box", host: "h", username: "u", initialPath: "/home/u")
        XCTAssertEqual(connection.resolvedUploadPath, "/home/u")
        connection.defaultUploadPath = "/srv/media"
        XCTAssertEqual(connection.resolvedUploadPath, "/srv/media")
        connection.defaultUploadPath = "   "
        XCTAssertEqual(connection.resolvedUploadPath, "/home/u")
        connection.initialPath = ""
        XCTAssertEqual(connection.resolvedUploadPath, ".")
    }

    /// A connection saved before `defaultUploadPath` existed must decode unchanged.
    func testConnectionBlobWithoutAnUploadPathDecodes() throws {
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","name":"box","host":"h","port":22,"username":"u","initialPath":".","useAgent":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SFTPConnection.self, from: legacy)
        XCTAssertNil(decoded.defaultUploadPath)
        XCTAssertEqual(decoded.resolvedUploadPath, ".")
    }

    // MARK: Error classification

    /// Retrying these can only make things worse — a changed host key never fixes itself, and repeated auth attempts earn a ban.
    func testUnfixableFailuresAreNotRetryable() {
        for kind in [SFTPError.Kind.hostKeyMismatch, .hostKey, .auth, .exists, .aborted] {
            XCTAssertFalse(SFTPError(kind: kind, message: "").isRetryable, "\(kind)")
        }
        for kind in [SFTPError.Kind.connect, .io, .verify, .rename, .stat] {
            XCTAssertTrue(SFTPError(kind: kind, message: "").isRetryable, "\(kind)")
        }
    }

    /// A mismatched host key is the one message that must never read as retryable advice.
    func testHostKeyMismatchSaysNothingWasSent() {
        let message = DownloadManager.remoteUploadMessage(
            for: SFTPError(kind: .hostKeyMismatch, message: "changed"), server: "media-box")
        XCTAssertTrue(message.contains("Nothing was sent"))
        XCTAssertTrue(message.contains("media-box"))
    }

    // MARK: Admission control

    func testGlobalAndPerServerCapsHold() async {
        let coordinator = RemoteUploadCoordinator(maxGlobal: 3, maxPerServer: 2)
        let server = UUID()
        try? await coordinator.acquire(server: server, remotePath: "/a")
        try? await coordinator.acquire(server: server, remotePath: "/b")
        var count = await coordinator.inFlightCount()
        XCTAssertEqual(count, 2)

        // A third on the same server must wait, while another server proceeds.
        let blocked = Task { try await coordinator.acquire(server: server, remotePath: "/c") }
        try? await Task.sleep(nanoseconds: 400_000_000)
        count = await coordinator.inFlightCount()
        XCTAssertEqual(count, 2, "per-server cap must hold")

        try? await coordinator.acquire(server: UUID(), remotePath: "/d")
        count = await coordinator.inFlightCount()
        XCTAssertEqual(count, 3)

        blocked.cancel()
        _ = try? await blocked.value
    }

    /// Two tasks writing one remote path would interleave truncating writes and corrupt the file.
    func testSamePathIsNotClaimedTwice() async {
        let coordinator = RemoteUploadCoordinator(maxGlobal: 4, maxPerServer: 4)
        let server = UUID()
        try? await coordinator.acquire(server: server, remotePath: "/srv/film.mkv")

        let blocked = Task { try await coordinator.acquire(server: server, remotePath: "/srv/film.mkv") }
        try? await Task.sleep(nanoseconds: 400_000_000)
        var count = await coordinator.inFlightCount()
        XCTAssertEqual(count, 1)

        await coordinator.release(server: server, remotePath: "/srv/film.mkv")
        _ = try? await blocked.value
        count = await coordinator.inFlightCount()
        XCTAssertEqual(count, 1, "the waiter should take the freed claim")
    }

    /// Cancelling while queued must leave nothing reserved, or the cap leaks a slot per cancellation.
    func testCancellingWhileQueuedReservesNothing() async {
        let coordinator = RemoteUploadCoordinator(maxGlobal: 1, maxPerServer: 1)
        let server = UUID()
        try? await coordinator.acquire(server: server, remotePath: "/a")

        let blocked = Task { try await coordinator.acquire(server: server, remotePath: "/b") }
        try? await Task.sleep(nanoseconds: 300_000_000)
        blocked.cancel()
        _ = try? await blocked.value

        await coordinator.release(server: server, remotePath: "/a")
        let count = await coordinator.inFlightCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: Circuit breaker

    func testBreakerOpensOnlyAfterTheThreshold() async {
        let coordinator = RemoteUploadCoordinator(failureThreshold: 3)
        let server = UUID()
        for _ in 0..<2 {
            await coordinator.recordFailure(server: server, retryable: true, reason: "timeout")
        }
        var hold = await coordinator.currentHold(server)
        XCTAssertNil(hold)

        await coordinator.recordFailure(server: server, retryable: true, reason: "timeout")
        hold = await coordinator.currentHold(server)
        XCTAssertNotNil(hold)
        if case .backoff = hold { } else { XCTFail("expected a timed backoff, got \(String(describing: hold))") }
    }

    /// A changed host key or a rejected password holds the server until the user acts — no timer should quietly resume it.
    func testUnfixableFailureHoldsImmediatelyAndIndefinitely() async {
        let coordinator = RemoteUploadCoordinator(failureThreshold: 3)
        let server = UUID()
        await coordinator.recordFailure(server: server, retryable: false, reason: "Host key changed")
        let hold = await coordinator.currentHold(server)
        guard case .manual(let reason) = hold else {
            return XCTFail("expected a manual hold, got \(String(describing: hold))")
        }
        XCTAssertEqual(reason, "Host key changed")
    }

    func testSuccessAndManualResetBothClearTheBreaker() async {
        let coordinator = RemoteUploadCoordinator(failureThreshold: 1)
        let server = UUID()
        await coordinator.recordFailure(server: server, retryable: false, reason: "bad password")
        var hold = await coordinator.currentHold(server)
        XCTAssertNotNil(hold)

        await coordinator.reset(server: server)
        hold = await coordinator.currentHold(server)
        XCTAssertNil(hold)

        await coordinator.recordFailure(server: server, retryable: false, reason: "bad password")
        await coordinator.recordSuccess(server: server)
        hold = await coordinator.currentHold(server)
        XCTAssertNil(hold)
    }

    /// A held server must not merely fail fast — it must not open a session at all.
    func testAHeldServerBlocksAdmission() async {
        let coordinator = RemoteUploadCoordinator(maxGlobal: 4, maxPerServer: 4, failureThreshold: 1)
        let server = UUID()
        await coordinator.recordFailure(server: server, retryable: false, reason: "held")

        let blocked = Task { try await coordinator.acquire(server: server, remotePath: "/a") }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let count = await coordinator.inFlightCount()
        XCTAssertEqual(count, 0)
        blocked.cancel()
        _ = try? await blocked.value
    }

    // MARK: Staging budget

    /// Counted from the declared total, not from bytes arrived: segmented HTTP preallocates the whole file at the first second, so measuring progress would notice too late.
    func testStagingBudgetCountsDeclaredSizeAndHoldsServerBoundTasksOnly() async {
        let manager = self.manager(enabled: true)
        let dir = makeTempDir()
        var settings = AppSettings()
        settings.sftpDestinationEnabled = true
        settings.sftpDestinationStagingBudgetGB = 1
        await manager.updateSettings(settings)

        let big = await manager.add(source: DownloadSource.parse("https://example.com/big.bin")!,
                                    saveDirectory: dir, totalBytes: 4 * 1024 * 1024 * 1024,
                                    remoteDestination: destination())
        let local = await manager.add(source: DownloadSource.parse("https://example.com/local.bin")!,
                                      saveDirectory: dir, totalBytes: 1024)

        let exceeded = await manager.remoteStagingBudgetExceeded()
        XCTAssertTrue(exceeded)

        let allowed = await manager.withinStagingBudget([big.id, local.id])
        XCTAssertEqual(allowed, [local.id], "only the server-bound download should be held back")
    }

    func testBudgetIsIgnoredWhileTheFeatureIsOff() async {
        let manager = self.manager(enabled: false)
        let exceeded = await manager.remoteStagingBudgetExceeded()
        XCTAssertFalse(exceeded)
    }
}
