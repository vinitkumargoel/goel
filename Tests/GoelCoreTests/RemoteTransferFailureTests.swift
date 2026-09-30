import XCTest
@testable import GoelCore

/// FTP/SFTP failures must say what actually went wrong: "checksum mismatch" for an unreadable file, "network
/// error" for a full disk and "couldn't create the folder" for everything send users down the wrong path.
final class RemoteTransferFailureTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-remote-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func events(of hub: EventHub, id: UUID, during body: () async -> Void) async -> [EngineEvent] {
        let stream = hub.subscribe(id)
        await body()
        hub.finishAll(id)
        var seen: [EngineEvent] = []
        for await event in stream { seen.append(event) }
        return seen
    }

    private func failure(in events: [EngineEvent]) -> DownloadError? {
        for event in events { if case .failed(let e) = event { return e } }
        return nil
    }

    private func completed(_ events: [EngineEvent]) -> Bool {
        events.contains { if case .finished = $0 { return true }; return false }
    }

    private let sha = Checksum(algorithm: .sha256, value: String(repeating: "0", count: 64))

    func testUnreadableFileIsNotReportedAsAChecksumMismatch() async {
        let hub = EventHub()
        let id = UUID()
        let missing = dir.appendingPathComponent("gone.iso")
        let seen = await events(of: hub, id: id) {
            await RemoteTransferPrep.finishWithOptionalChecksum(
                hub: hub, id: id, name: "gone.iso", fileURL: missing, written: 10, expected: sha)
        }
        let error = failure(in: seen)
        XCTAssertNotNil(error)
        XCTAssertNotEqual(error, .checksumMismatch, "an I/O error must not tell the user their file is bad")
        XCTAssertTrue(error?.message.contains("Couldn’t verify") == true, error?.message ?? "")
    }

    func testCancelledVerifyReportsNothing() async throws {
        let hub = EventHub()
        let id = UUID()
        let file = dir.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 4 << 20).write(to: file)
        let stream = hub.subscribe(id)
        let job = Task {
            await RemoteTransferPrep.finishWithOptionalChecksum(
                hub: hub, id: id, name: "big.bin", fileURL: file, written: 4 << 20, expected: self.sha)
        }
        job.cancel()
        await job.value
        hub.finishAll(id)
        var seen: [EngineEvent] = []
        for await event in stream { seen.append(event) }
        XCTAssertNil(failure(in: seen), "a pause mid-verify is not a mismatch")
        XCTAssertFalse(completed(seen), "nor a completion")
    }

    func testRealMismatchIsStillAMismatch() async throws {
        let hub = EventHub()
        let id = UUID()
        let file = dir.appendingPathComponent("ok.bin")
        try Data("hello".utf8).write(to: file)
        let seen = await events(of: hub, id: id) {
            await RemoteTransferPrep.finishWithOptionalChecksum(
                hub: hub, id: id, name: "ok.bin", fileURL: file, written: 5, expected: sha)
        }
        XCTAssertEqual(failure(in: seen), .checksumMismatch)
    }

    func testDiskFullIsRecognisedThroughUnderlyingErrors() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertTrue(RemoteTransferPrep.isDiskFull(posix))
        XCTAssertTrue(RemoteTransferPrep.isDiskFull(cocoa))
        XCTAssertTrue(RemoteTransferPrep.isDiskFull(wrapped))
        XCTAssertFalse(RemoteTransferPrep.isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    func testWriteFailureMapsDiskFullToDiskFullNotNetwork() {
        let error = RemoteTransferPrep.writeFailure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            fileURL: dir.appendingPathComponent("x.iso"), needed: 1_000, log: GoelLog.engineFTP)
        guard case .diskFull(let needed, _) = error else {
            return XCTFail("ENOSPC must surface as diskFull, got \(error)")
        }
        XCTAssertEqual(needed, 1_000)
    }

    func testPrepFailureKeepsTheUnderlyingReason() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteNoPermission.rawValue,
                             userInfo: [NSLocalizedDescriptionKey: "You don’t have permission."])
        let error = RemoteTransferPrep.prepFailure(denied, saveDirectory: "/Volumes/RO/dl",
                                                   log: GoelLog.engineSFTP)
        XCTAssertFalse(error.message.contains("create the download folder"))
        XCTAssertTrue(error.message.contains("permission"), error.message)
        XCTAssertTrue(error.message.contains("/Volumes/RO/dl"), error.message)
    }

    func testPrepFailurePassesDownloadErrorsThrough() {
        XCTAssertEqual(RemoteTransferPrep.prepFailure(DownloadError.fileMissing, saveDirectory: "/x",
                                                     log: GoelLog.engineFTP), .fileMissing)
    }

    func testRemoveSavedFileLeavesNothingAtThePath() throws {
        let file = dir.appendingPathComponent("remove-me-\(UUID().uuidString).bin")
        try Data([1]).write(to: file)
        try RemoteTransferPrep.trashOrDelete(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTrashOrDeleteOfAMissingFileThrows() {
        XCTAssertThrowsError(try RemoteTransferPrep.trashOrDelete(dir.appendingPathComponent("nope")))
    }

    // MARK: - FTP credentials (FFI-8)

    func testInlineFTPSCredentialsRequireTLS() {
        let url = URL(string: "ftps://alice:secret@files.example.com/a.iso")!
        let creds = FTPEngine.credentials(for: url, lookup: { _ in nil })
        XCTAssertEqual(creds?.userpwd, "alice:secret")
        XCTAssertEqual(creds?.requireTLS, true, "a user who typed ftps:// must never fall back to plaintext")
    }

    func testKeychainCredentialsAlwaysRequireTLS() {
        let url = URL(string: "ftp://files.example.com/a.iso")!
        let creds = FTPEngine.credentials(for: url, lookup: { _ in ("bob", "pw") })
        XCTAssertEqual(creds?.requireTLS, true)
    }

    func testInlinePlainFTPCredentialsKeepOpportunisticTLS() {
        let url = URL(string: "ftp://alice:secret@files.example.com/a.iso")!
        XCTAssertEqual(FTPEngine.credentials(for: url, lookup: { _ in nil })?.requireTLS, false)
    }
}
