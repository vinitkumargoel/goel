import XCTest
@testable import GoelCore

/// Boundary tests unlocked by the ``CredentialManaging`` port: `SFTPConnectionStore`
/// now injects the credential store (and, for tests, its file directory), so
/// password persistence / removal is testable against an in-memory fake — without
/// a live Keychain and without touching the user's real Application Support.
final class CredentialManagingPortTests: XCTestCase {

    /// A minimal in-memory ``CredentialManaging`` standing in for the Keychain.
    private final class FakeCredentialStore: CredentialManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: (user: String, pass: String)] = [:]

        func credential(forHost host: String) -> (username: String, password: String)? {
            lock.lock(); defer { lock.unlock() }
            return store[host].map { ($0.user, $0.pass) }
        }
        @discardableResult func setCredential(username: String, password: String, host: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            store[host] = (username, password); return true
        }
        @discardableResult func removeCredential(host: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return store.removeValue(forKey: host) != nil
        }
        func allCredentials() -> [HostCredential] {
            lock.lock(); defer { lock.unlock() }
            return store.map { HostCredential(host: $0.key, username: $0.value.user) }
        }
    }

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sftpstore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSavePersistsPasswordUnderCredentialKey() {
        let fake = FakeCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "home", host: "nas.local", port: 22, username: "vinit")
        store.save(conn, password: "hunter2")
        XCTAssertEqual(fake.credential(forHost: conn.credentialKey)?.password, "hunter2",
                       "the secret is stored under user@host:port, not the file")
        XCTAssertEqual(store.password(for: conn), "hunter2")
        XCTAssertEqual(store.password(user: "vinit", host: "nas.local", port: 22), "hunter2",
                       "ad-hoc user@host:port lookup resolves the same secret")
    }

    func testSaveWithNilPasswordLeavesExistingSecret() {
        let fake = FakeCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "home", host: "h", username: "u")
        store.save(conn, password: "keep")
        store.save(conn, password: nil)   // edit without retyping
        XCTAssertEqual(store.password(for: conn), "keep")
    }

    func testRemoveClearsStoredSecret() {
        let fake = FakeCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "home", host: "h", username: "u")
        store.save(conn, password: "secret")
        store.remove(conn.id)
        XCTAssertNil(store.password(for: conn), "removing the connection clears its stored secret")
        XCTAssertTrue(store.load().isEmpty)
    }

    func testListRoundTripsThroughInjectedDirectory() {
        let store = SFTPConnectionStore(credentials: FakeCredentialStore(), directory: tempDir())
        let a = SFTPConnection(name: "a", host: "h1", username: "u1")
        let b = SFTPConnection(name: "b", host: "h2", username: "u2")
        store.save(a, password: "x")
        store.save(b, password: "y")
        XCTAssertEqual(Set(store.load().map(\.id)), Set([a.id, b.id]))
    }
}
