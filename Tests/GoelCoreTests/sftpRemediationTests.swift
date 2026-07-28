import XCTest
@testable import GoelCore

final class SFTPRemediationTests: XCTestCase {

    /// An unreadable directory folded into an empty set skipped the prompt and truncated live files.
    func testOverwriteSplitRefusesAnUnavailableListing() {
        XCTAssertNil(SFTPOverwritePlan.split(names: ["a.txt", "b.txt"], against: .unavailable))
    }

    func testOverwriteSplitOnEmptyDirectoryLeavesEverythingFree() {
        let split = SFTPOverwritePlan.split(names: ["a.txt", "b.txt"], against: .names([]))
        XCTAssertEqual(split?.free, [0, 1])
        XCTAssertEqual(split?.colliding, [])
    }

    func testOverwriteSplitFlagsExistingNames() {
        let split = SFTPOverwritePlan.split(names: ["a.txt", "b.txt"],
                                            against: .names(["b.txt"]))
        XCTAssertEqual(split?.free, [0])
        XCTAssertEqual(split?.colliding, [1])
    }

    /// Two picks sharing a last path component, both "free", would race two writers onto one remote path.
    func testOverwriteSplitFlagsARepeatWithinOneBatch() {
        let split = SFTPOverwritePlan.split(names: ["photo.jpg", "photo.jpg", "photo.jpg"],
                                            against: .names([]))
        XCTAssertEqual(split?.free, [0])
        XCTAssertEqual(split?.colliding, [1, 2])
    }

    private static let fingerprintA = String(repeating: "ab", count: 32)
    private static let fingerprintB = String(repeating: "cd", count: 32)
    private let key = "GoelDownloader.SSHHostKeys"

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "goel.hostkey.remediation.\(UUID().uuidString)")!
    }

    func testPinRoundTripsAndAbsentHostReadsAsNone() {
        let store = HostKeyStore(defaults: freshDefaults())
        XCTAssertEqual(store.lookup(host: "h", port: 22), .none)
        XCTAssertTrue(store.setFingerprint(Self.fingerprintA, host: "H", port: 22))
        XCTAssertEqual(store.lookup(host: "h", port: 22), .pinned(Self.fingerprintA))
        XCTAssertEqual(store.lookup(host: "h", port: 2222), .none)
    }

    /// A non-`[String: String]` record reading as "no pins" downgrades every server to trust-on-first-use.
    func testGarbageRecordReadsAsUnavailableNotEmpty() {
        let defaults = freshDefaults()
        defaults.set(["nas.local:22": 17], forKey: key)
        let store = HostKeyStore(defaults: defaults)
        XCTAssertEqual(store.lookup(host: "nas.local", port: 22), .unavailable)
        XCTAssertEqual(store.lookup(host: "other.local", port: 22), .unavailable)
    }

    /// An empty value makes the shim skip the comparison (`expected_fp[0]`): unverified but looking pinned.
    func testEmptyStoredFingerprintReadsAsUnavailableNotNone() {
        let defaults = freshDefaults()
        defaults.set(["nas.local:22": ""], forKey: key)
        let store = HostKeyStore(defaults: defaults)
        XCTAssertEqual(store.lookup(host: "nas.local", port: 22), .unavailable)
    }

    func testMalformedFingerprintReadsAsUnavailable() {
        let defaults = freshDefaults()
        defaults.set(["nas.local:22": "not-a-fingerprint"], forKey: key)
        XCTAssertEqual(HostKeyStore(defaults: defaults).lookup(host: "nas.local", port: 22),
                       .unavailable)
    }

    /// `setFingerprint` writing back `all()` after a bad read replaced the map and erased every other pin.
    func testWriteOnAnUnreadableStoreChangesNothing() {
        let defaults = freshDefaults()
        defaults.set(["nas.local:22": 17], forKey: key)
        let store = HostKeyStore(defaults: defaults)
        XCTAssertFalse(store.setFingerprint(Self.fingerprintA, host: "new.local", port: 22))
        let raw = defaults.object(forKey: key) as? [String: Any]
        XCTAssertNotNil(raw?["nas.local:22"], "the unreadable record must still be there")
        XCTAssertNil(raw?["new.local:22"], "the whole map must not be replaced by one entry")
    }

    func testMalformedFingerprintIsNeverWritten() {
        let defaults = freshDefaults()
        let store = HostKeyStore(defaults: defaults)
        XCTAssertFalse(store.setFingerprint("", host: "nas.local", port: 22))
        XCTAssertFalse(store.setFingerprint("ABCD", host: "nas.local", port: 22))
        XCTAssertEqual(store.lookup(host: "nas.local", port: 22), .none)
    }

    func testPinningOneHostKeepsAnother() {
        let store = HostKeyStore(defaults: freshDefaults())
        store.setFingerprint(Self.fingerprintA, host: "a.local", port: 22)
        store.setFingerprint(Self.fingerprintB, host: "b.local", port: 22)
        XCTAssertEqual(store.lookup(host: "a.local", port: 22), .pinned(Self.fingerprintA))
        XCTAssertEqual(store.lookup(host: "b.local", port: 22), .pinned(Self.fingerprintB))
    }

    func testResetForgetsOnlyTheNamedHost() {
        let store = HostKeyStore(defaults: freshDefaults())
        store.setFingerprint(Self.fingerprintA, host: "a.local", port: 22)
        store.setFingerprint(Self.fingerprintB, host: "b.local", port: 22)
        XCTAssertTrue(store.reset(host: "a.local", port: 22))
        XCTAssertEqual(store.lookup(host: "a.local", port: 22), .none)
        XCTAssertEqual(store.lookup(host: "b.local", port: 22), .pinned(Self.fingerprintB))
    }

    /// Reset is the only escape from a store that refuses every connection, so it must survive a bad record.
    func testResetClearsAnUnreadableStore() {
        let defaults = freshDefaults()
        defaults.set(["nas.local:22": 17], forKey: key)
        let store = HostKeyStore(defaults: defaults)
        XCTAssertTrue(store.reset(host: "nas.local", port: 22))
        XCTAssertEqual(store.lookup(host: "nas.local", port: 22), .none)
    }

    private final class RecordingApprover: HostKeyApproving, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let answer: Bool
        init(answer: Bool) { self.answer = answer }
        func approveFirstContact(host: String, port: Int, fingerprint: String) async -> Bool {
            record()
            return answer
        }
        private func record() { lock.lock(); calls += 1; lock.unlock() }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    /// A pinned server is decided by the pin; re-asking trains the user to click through the dialog.
    func testApproverIsNotConsultedWhenAPinExists() async {
        let defaults = freshDefaults()
        let store = HostKeyStore(defaults: defaults)
        store.setFingerprint(Self.fingerprintA, host: "127.0.0.1", port: 1)
        let approver = RecordingApprover(answer: true)
        let previous = HostKeyTrust.shared.approver
        HostKeyTrust.shared.approver = approver
        defer { HostKeyTrust.shared.approver = previous }

        let client = SFTPClient(target: SFTPTarget(host: "127.0.0.1", port: 1,
                                                   username: "u", password: "p"),
                                hostKeys: store)
        // Nothing is listening: the socket failure is expected, only the decision before it is asserted.
        _ = try? await client.list(".")
        XCTAssertEqual(approver.callCount, 0)
    }

    /// An unreadable pin refuses before the socket opens, never re-learning an already-verified server's key.
    func testUnreadablePinRecordRefusesWithoutConnecting() async {
        let defaults = freshDefaults()
        defaults.set(["127.0.0.1:1": 17], forKey: key)
        let client = SFTPClient(target: SFTPTarget(host: "127.0.0.1", port: 1,
                                                   username: "u", password: "p"),
                                hostKeys: HostKeyStore(defaults: defaults))
        do {
            _ = try await client.list(".")
            XCTFail("an unreadable pin record must refuse the connection")
        } catch let e as SFTPError {
            XCTAssertEqual(e.kind, .hostKey)
            XCTAssertTrue(e.message.contains("Reset the pinned host key"), e.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A pre-flight that never reaches the server pins nothing.
    func testFirstContactPinsNothingWhenTheServerIsUnreachable() async {
        let defaults = freshDefaults()
        let store = HostKeyStore(defaults: defaults)
        let approver = RecordingApprover(answer: true)
        let previous = HostKeyTrust.shared.approver
        HostKeyTrust.shared.approver = approver
        defer { HostKeyTrust.shared.approver = previous }

        let client = SFTPClient(target: SFTPTarget(host: "127.0.0.1", port: 1,
                                                   username: "u", password: "p"),
                                hostKeys: store)
        _ = try? await client.list(".")
        XCTAssertEqual(approver.callCount, 0, "nothing to approve — no key was ever read")
        XCTAssertEqual(store.lookup(host: "127.0.0.1", port: 1), .none)
    }

    func testShortfallReportsMissingBytes() {
        XCTAssertEqual(TransferCompletion.shortfall(expected: 1000, written: 400), 600)
        XCTAssertEqual(TransferCompletion.shortfall(expected: 1, written: 0), 1)
    }

    func testShortfallIsNilWhenNothingIsOwed() {
        XCTAssertNil(TransferCompletion.shortfall(expected: 1000, written: 1000))
        // The source grew mid-transfer — not a truncation.
        XCTAssertNil(TransferCompletion.shortfall(expected: 1000, written: 1200))
        // Size never known: an unstatable remote file, or a zero-length source.
        XCTAssertNil(TransferCompletion.shortfall(expected: 0, written: 0))
        XCTAssertNil(TransferCompletion.shortfall(expected: -1, written: 0))
    }

    func testUnsafeChildNamesAreRejected() {
        XCTAssertFalse(SFTPBrowserPaths.isSafeChildName(".."))
        XCTAssertFalse(SFTPBrowserPaths.isSafeChildName("."))
        XCTAssertFalse(SFTPBrowserPaths.isSafeChildName(""))
        XCTAssertFalse(SFTPBrowserPaths.isSafeChildName("a/b"))
        XCTAssertFalse(SFTPBrowserPaths.isSafeChildName("../.."))
        XCTAssertFalse(SFTPBrowserPaths.isSafeChildName("/etc"))
    }

    func testOrdinaryChildNamesAreAccepted() {
        XCTAssertTrue(SFTPBrowserPaths.isSafeChildName(".config"))
        XCTAssertTrue(SFTPBrowserPaths.isSafeChildName("My Folder"))
        XCTAssertTrue(SFTPBrowserPaths.isSafeChildName("...."))
    }
}
