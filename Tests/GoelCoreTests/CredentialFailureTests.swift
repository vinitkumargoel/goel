import XCTest
@testable import GoelCore

final class CredentialFailureTests: XCTestCase {

    private final class DenyingCredentialStore: CredentialManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: (user: String, pass: String)] = [:]
        var denyReads = false
        var denyWrites = false
        private(set) var writeAttempts = 0

        func seed(host: String, user: String, pass: String) {
            lock.lock(); defer { lock.unlock() }
            store[host] = (user, pass)
        }
        func rawPassword(host: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return store[host]?.pass
        }

        func credential(forHost host: String) -> (username: String, password: String)? {
            guard case .found(let u, let p) = lookupCredential(forHost: host) else { return nil }
            return (u, p)
        }

        func lookupCredential(forHost host: String) -> CredentialLookup {
            if denyReads { return .denied(status: -128) }      // errSecUserCanceled
            lock.lock(); defer { lock.unlock() }
            guard let e = store[host] else { return .notFound }
            return .found(username: e.user, password: e.pass)
        }

        @discardableResult
        func setCredential(username: String, password: String, host: String) -> Bool {
            storeCredential(username: username, password: password, host: host).didStore
        }

        @discardableResult
        func storeCredential(username: String, password: String, host: String) -> CredentialWrite {
            lock.lock(); defer { lock.unlock() }
            writeAttempts += 1
            if denyWrites { return .denied(status: -128) }
            store[host] = (username, password)
            return .stored
        }

        @discardableResult
        func removeCredential(host: String) -> Bool {
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
            .appendingPathComponent("credfail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDeniedReadIsNotReportedAsMissing() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "n", host: "h", username: "u")
        store.save(conn, password: "secret")

        fake.denyReads = true
        XCTAssertEqual(store.passwordLookup(for: conn), .denied(status: -128),
                       "a refused read must be distinguishable from an absent entry")
        XCTAssertTrue(store.passwordLookup(for: conn).isRetryable)
        XCTAssertNil(store.password(for: conn),
                     "the convenience accessor still yields nil, but callers can now ask why")
    }

    func testResolveSurfacesDeniedCredentialsInsteadOfConnectingWithout() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "n", host: "h", username: "u")
        store.save(conn, password: "secret")
        fake.denyReads = true

        switch SFTPSession.resolve(for: conn, store: store) {
        case .credentialsUnavailable(let lookup):
            XCTAssertTrue(lookup.isRetryable)
        case .ready:
            XCTFail("must not build a client with no credential when the read was refused")
        case .incomplete:
            XCTFail("the connection is complete; only the secret was unreadable")
        }
    }

    func testExplicitPasswordBypassesTheKeychainEntirely() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "n", host: "h", username: "u")
        fake.denyReads = true

        guard case .ready = SFTPSession.resolve(for: conn, password: "typed", store: store) else {
            return XCTFail("an explicitly supplied password should not consult the Keychain")
        }
    }

    func testEditedHostStillFindsTheSecretSavedUnderTheOldIdentity() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let saved = SFTPConnection(name: "n", host: "old.example", username: "u")
        store.save(saved, password: "secret")

        let draft = SFTPConnection(id: saved.id, name: "n", host: "new.example", username: "u")
        XCTAssertNil(store.password(for: draft),
                     "precondition: the draft's own key has no secret")

        guard case .ready = SFTPSession.resolve(for: draft, credentialIdentity: saved,
                                                store: store) else {
            return XCTFail("Test must read the secret from the saved identity, not the draft")
        }
        guard case .ready(let bare) = SFTPSession.resolve(for: draft, store: store) else {
            return XCTFail("unexpected resolution for the un-hinted draft")
        }
        XCTAssertNil(bare.target.password)
    }

    func testPassphraseIsNotConsultedWithoutAKey() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "n", host: "h", username: "u")
        fake.seed(host: conn.credentialKey, user: "u", pass: "pw")

        guard case .ready = SFTPSession.resolve(for: conn, store: store) else {
            return XCTFail("a key-less connection must not be blocked by the passphrase entry")
        }
    }

    func testDeniedWriteIsReportedAndDoesNotDestroyTheStoredSecret() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "n", host: "h", username: "u")
        store.save(conn, password: "original")

        fake.denyWrites = true
        let outcome = store.save(conn, password: "replacement")

        XCTAssertEqual(outcome, .denied(status: -128), "a refused write must be reported, not silent")
        XCTAssertTrue(outcome.isRetryable)
        XCTAssertEqual(fake.rawPassword(host: conn.credentialKey), "original",
                       "a refused write must leave the existing secret intact")
    }

    func testFailedMigrationKeepsTheOldSecret() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        var conn = SFTPConnection(name: "n", host: "h", username: "u")
        store.save(conn, password: "carry-me")
        let oldKey = conn.credentialKey

        fake.denyWrites = true
        conn.username = "renamed"
        let outcome = store.save(conn, password: nil)

        XCTAssertEqual(outcome, .denied(status: -128))
        XCTAssertEqual(fake.rawPassword(host: oldKey), "carry-me",
                       "the old entry must survive a migration whose write was refused")
    }

    func testSuccessfulMigrationMovesTheSecretAndClearsTheOldKey() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        var conn = SFTPConnection(name: "n", host: "h", username: "u")
        store.save(conn, password: "carry-me")
        let oldKey = conn.credentialKey

        conn.username = "renamed"
        XCTAssertEqual(store.save(conn, password: nil), .stored)
        XCTAssertEqual(fake.rawPassword(host: conn.credentialKey), "carry-me")
        XCTAssertNil(fake.rawPassword(host: oldKey), "the stale entry is cleared once the new one lands")
    }

    func testEmptyPasswordClearsTheStoredSecret() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "n", host: "h", username: "u")
        store.save(conn, password: "secret")

        store.save(conn, password: "")
        XCTAssertNil(fake.rawPassword(host: conn.credentialKey))
    }

    func testKeyPassphraseRoundTripsAndIsSeparateFromThePassword() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "n", host: "h", username: "u",
                                  privateKeyPath: "/keys/id_ed25519")
        store.save(conn, password: "pw", keyPassphrase: "phrase")

        XCTAssertEqual(store.password(for: conn), "pw")
        XCTAssertEqual(store.keyPassphrase(for: conn), "phrase")
        XCTAssertNotEqual(conn.credentialKey, conn.keyPassphraseKey,
                          "the two secrets must never collide in the Keychain")
    }

    func testRemovingAConnectionClearsBothSecrets() {
        let fake = DenyingCredentialStore()
        let store = SFTPConnectionStore(credentials: fake, directory: tempDir())
        let conn = SFTPConnection(name: "n", host: "h", username: "u",
                                  privateKeyPath: "/keys/id_ed25519")
        store.save(conn, password: "pw", keyPassphrase: "phrase")
        store.remove(conn.id)

        XCTAssertNil(fake.rawPassword(host: conn.credentialKey))
        XCTAssertNil(fake.rawPassword(host: conn.keyPassphraseKey),
                     "the passphrase must not outlive the connection it belonged to")
    }

    func testPrivateKeyPathSurvivesJSONRoundTrip() throws {
        let conn = SFTPConnection(name: "n", host: "h", username: "u",
                                  privateKeyPath: "/keys/id_ed25519")
        let decoded = try JSONDecoder().decode(SFTPConnection.self,
                                               from: JSONEncoder().encode(conn))
        XCTAssertEqual(decoded.privateKeyPath, "/keys/id_ed25519")
    }

    func testConnectionsSavedBeforeKeySupportStillDecode() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","name":"old","host":"h","port":22,
          "username":"u","initialPath":".","useAgent":false}]
        """
        let list = try JSONDecoder().decode([SFTPConnection].self, from: Data(legacy.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].privateKeyPath)
    }
}
