import XCTest
@testable import GoelCore

/// Pure construction checks for ``SFTPSession`` — no network, no Keychain.
final class SFTPSessionTests: XCTestCase {

    /// Minimal in-memory ``CredentialManaging`` so store-backed paths don't touch
    /// the real Keychain.
    private final class MemCreds: CredentialManaging, @unchecked Sendable {
        private var store: [String: (user: String, pass: String)] = [:]
        func credential(forHost host: String) -> (username: String, password: String)? {
            store[host].map { ($0.user, $0.pass) }
        }
        @discardableResult func setCredential(username: String, password: String, host: String) -> Bool {
            store[host] = (username, password); return true
        }
        @discardableResult func removeCredential(host: String) -> Bool {
            store.removeValue(forKey: host) != nil
        }
        func allCredentials() -> [HostCredential] {
            store.map { HostCredential(host: $0.key, username: $0.value.user) }
        }
    }

    private func tempStore() -> (SFTPConnectionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel.sftp-session.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SFTPConnectionStore(credentials: MemCreds(), directory: dir), dir)
    }

    func testClientForTargetPreservesAuth() {
        let target = SFTPTarget(host: "nas.local", port: 2222, username: "vinit",
                                password: "secret", useAgent: true)
        let client = SFTPSession.client(for: target)
        XCTAssertEqual(client.target, target)
    }

    func testClientForConnectionNilHost() {
        let conn = SFTPConnection(name: "x", host: "", username: "u")
        XCTAssertNil(SFTPSession.client(for: conn, password: "x"),
                     "empty host cannot build a target")
    }

    func testClientForConnectionUsesExplicitPassword() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conn = SFTPConnection(name: "nas", host: "nas.local", port: 22, username: "vinit")
        store.save(conn, password: "from-store")

        let client = SFTPSession.client(for: conn, password: "typed", store: store)
        XCTAssertEqual(client?.target.password, "typed")
        XCTAssertEqual(client?.target.host, "nas.local")
        XCTAssertEqual(client?.target.username, "vinit")
    }

    func testClientForConnectionFallsBackToStore() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conn = SFTPConnection(name: "nas", host: "nas.local", port: 22, username: "vinit")
        store.save(conn, password: "from-store")

        let client = SFTPSession.client(for: conn, store: store)
        XCTAssertEqual(client?.target.password, "from-store")
    }

    func testClientForURLInlinePassword() {
        let url = URL(string: "sftp://alice:secret@example.com:2222/home/alice/f.bin")!
        let client = SFTPSession.client(for: url)
        XCTAssertEqual(client?.target.host, "example.com")
        XCTAssertEqual(client?.target.port, 2222)
        XCTAssertEqual(client?.target.username, "alice")
        XCTAssertEqual(client?.target.password, "secret")
    }

    func testClientForURLMissingUser() {
        XCTAssertNil(SFTPSession.client(for: URL(string: "sftp://example.com/f.bin")!))
    }
}
