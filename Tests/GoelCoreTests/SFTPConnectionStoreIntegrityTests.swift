import XCTest
@testable import GoelCore

/// `sftp-connections.json` is a read-modify-write store. When an undecodable file collapsed to "no
/// servers", the very next save rewrote the file containing *only* the profile being edited — one bad
/// byte silently deleted every other saved server. The fix reports the failure instead, and these tests
/// pin both halves of it: the caller is told nothing landed, AND the bytes on disk are untouched. The
/// second assertion is the data-loss regression; the first is only how the user finds out.
final class SFTPConnectionStoreIntegrityTests: XCTestCase {

    /// Records every mutation so a test can prove the Keychain was never reached either — a secret
    /// migrated for a profile that never landed is stranded under a key nothing reads.
    private final class RecordingCredentialStore: CredentialManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (user: String, pass: String)] = [:]
        private(set) var writes: [String] = []
        private(set) var removals: [String] = []

        func credential(forHost host: String) -> (username: String, password: String)? {
            lock.lock(); defer { lock.unlock() }
            return entries[host].map { ($0.user, $0.pass) }
        }

        @discardableResult
        func setCredential(username: String, password: String, host: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            entries[host] = (username, password)
            writes.append(host)
            return true
        }

        @discardableResult
        func removeCredential(host: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            removals.append(host)
            return entries.removeValue(forKey: host) != nil
        }

        func allCredentials() -> [HostCredential] {
            lock.lock(); defer { lock.unlock() }
            return entries.map { HostCredential(host: $0.key, username: $0.value.user) }
        }

        var touchedKeychain: Bool {
            lock.lock(); defer { lock.unlock() }
            return !writes.isEmpty || !removals.isEmpty
        }
    }

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-sftp-store-integrity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// The exact bytes the store must refuse to touch. Valid UTF-8 but not a `[SFTPConnection]`, which is
    /// what a truncated write or a half-synced cloud folder actually leaves behind.
    private static let garbage = Data("{\"corrupt\": not-json, ".utf8)

    private func storeWithCorruptFile() -> (SFTPConnectionStore, RecordingCredentialStore, URL) {
        let dir = makeTempDir()
        let fileURL = dir.appendingPathComponent("sftp-connections.json")
        try? Self.garbage.write(to: fileURL)
        let keychain = RecordingCredentialStore()
        return (SFTPConnectionStore(credentials: keychain, directory: dir), keychain, fileURL)
    }

    /// Stable identity: `SFTPConnection.id` defaults to a fresh UUID, so a factory would make
    /// "the profile we saved" and "the profile we removed" two different servers.
    private let subject = SFTPConnection(name: "nas", host: "nas.local", port: 22, username: "vinit")

    func testSaveOutcomeOnAnUndecodableFileReportsNotSavedAndLeavesEveryOtherServerOnDisk() {
        let (store, keychain, fileURL) = storeWithCorruptFile()

        let outcome = store.saveOutcome(subject, password: "hunter2")

        XCTAssertEqual(outcome, .notSaved(.unreadable),
                       "an undecodable connections file is not an empty list — reporting `.saved` here is how the user was told a server was added while the file was being emptied")
        XCTAssertEqual(try Data(contentsOf: fileURL), Self.garbage,
                       "the store rewrote a file it could not read: every other saved server was replaced by the one profile being edited")
        XCTAssertFalse(keychain.touchedKeychain,
                       "the secret was migrated for a profile that never reached the file, stranding it under a key nothing will ever read")
    }

    func testSaveReportsAFailedWriteRatherThanClaimingTheKeychainStoredIt() {
        let (store, _, fileURL) = storeWithCorruptFile()

        // `save` can only speak about the Keychain, so a refused file write has to surface as a
        // non-`.stored` result — anything else lets a caller report "saved" for a lost profile.
        let write = store.save(subject, password: "hunter2")

        XCTAssertFalse(write.didStore,
                       "`save` claimed the credential was stored even though the profile never reached the file")
        XCTAssertEqual(try Data(contentsOf: fileURL), Self.garbage,
                       "`save` rewrote an unreadable connections file, discarding every other saved server")
    }

    func testRemoveOnAnUndecodableFileReportsUnreadableAndLeavesTheFileByteIdentical() {
        let (store, keychain, fileURL) = storeWithCorruptFile()

        let failure = store.remove(subject.id)

        XCTAssertEqual(failure, .unreadable,
                       "a delete against an unreadable file must report failure — silently succeeding leaves the row gone from the UI but the server still in the file")
        XCTAssertEqual(try Data(contentsOf: fileURL), Self.garbage,
                       "the delete rewrote a file it could not read, taking every other saved server with it")
        XCTAssertFalse(keychain.touchedKeychain,
                       "the secret was wiped for a server that is still listed in the file, leaving a profile nobody can connect to")
    }

    /// Guards the fix against over-correcting: only an *undecodable* file is refused. A missing file is
    /// still legitimately an empty list, and a readable one still merges.
    func testAReadableFileStillAcceptsAnUpsertAlongsideTheServersAlreadyInIt() throws {
        let dir = makeTempDir()
        let fileURL = dir.appendingPathComponent("sftp-connections.json")
        let existing = SFTPConnection(name: "other", host: "other.local", port: 22, username: "root")
        try JSONEncoder().encode([existing]).write(to: fileURL)
        let store = SFTPConnectionStore(credentials: RecordingCredentialStore(), directory: dir)

        let outcome = store.saveOutcome(subject, password: "hunter2")

        XCTAssertEqual(outcome, .saved(.stored))
        XCTAssertEqual(Set(store.load().map(\.id)), [existing.id, subject.id],
                       "refusing undecodable files must not also refuse decodable ones")
    }
}
