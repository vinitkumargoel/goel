import Foundation

/// Persists the user's saved SFTP servers: the list (minus secrets) as JSON in
/// Application Support, and each password in the Keychain. Thread-safe.
public final class SFTPConnectionStore: @unchecked Sendable {

    public static let shared = SFTPConnectionStore()

    /// Injected credential store (``CredentialManaging``) and a test-override base directory; both
    /// default to production behaviour so `SFTPConnectionStore()` and `.shared` are unchanged.
    private let keychain: any CredentialManaging
    private let directoryOverride: URL?
    private let lock = NSLock()

    private var fileURL: URL {
        let base = directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GoelDownloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sftp-connections.json")
    }

    public init(credentials: any CredentialManaging = KeychainCredentialStore(),
                directory: URL? = nil) {
        self.keychain = credentials
        self.directoryOverride = directory
    }

    /// All saved connections, newest first is not implied — insertion order.
    public func load() -> [SFTPConnection] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([SFTPConnection].self, from: data) else {
            return []
        }
        return list
    }

    /// Insert or replace a connection; nil `password` keeps the stored secret, "" clears it. Returns
    /// what happened to the *secrets* — only the Keychain half can be refused, and refusal is retryable.
    @discardableResult
    public func save(_ connection: SFTPConnection, password: String?,
                     keyPassphrase: String? = nil) -> CredentialWrite {
        lock.lock()
        var list = (try? JSONDecoder().decode([SFTPConnection].self,
                                              from: (try? Data(contentsOf: fileURL)) ?? Data())) ?? []
        let previous = list.first { $0.id == connection.id }
        if let idx = list.firstIndex(where: { $0.id == connection.id }) {
            list[idx] = connection
        } else {
            list.append(connection)
        }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
        lock.unlock()

        // Keychain is keyed by `credentialKey` (user@host:port) from mutable fields, so an edit moves
        // the key: migrate then delete, or blank-password edits orphan the secret and break the login.
        let keyChanged = previous.map { $0.credentialKey != connection.credentialKey } ?? false

        // Worst outcome across every secret written, preferring `denied` — it is
        // the retryable one, so it is what the UI should offer to repeat.
        var deniedStatus: Int32?
        var failedStatus: Int32?
        func note(_ write: CredentialWrite) {
            switch write {
            case .stored: break
            case .denied(let s): deniedStatus = deniedStatus ?? s
            case .failed(let s): failedStatus = failedStatus ?? s
            }
        }

        /// Write `secret` under the connection's key, dropping the stale entry only once the new one
        /// is in place — deleting first means a refused Keychain prompt destroys the only copy.
        func migrate(secret: String?, newKey: String, oldKey: String?) {
            if let secret {
                let write = keychain.storeCredential(username: connection.username,
                                                     password: secret, host: newKey)
                note(write)
                if write.didStore, let oldKey, oldKey != newKey {
                    keychain.removeCredential(host: oldKey)
                }
                return
            }
            // Secret untouched but its key moved: carry the stored value over.
            guard let oldKey, oldKey != newKey else { return }
            switch keychain.lookupCredential(forHost: oldKey) {
            case .found(_, let stored):
                let write = keychain.storeCredential(username: connection.username,
                                                     password: stored, host: newKey)
                note(write)
                if write.didStore { keychain.removeCredential(host: oldKey) }
            case .notFound:
                break
            // Can't read the old secret, so we cannot migrate it — but crucially
            // we also do NOT delete it. Report so the user can retry.
            case .denied(let s): deniedStatus = deniedStatus ?? s
            case .failed(let s): failedStatus = failedStatus ?? s
            }
        }

        if let password, password.isEmpty {
            keychain.removeCredential(host: connection.credentialKey)
            if keyChanged, let previous { keychain.removeCredential(host: previous.credentialKey) }
        } else {
            migrate(secret: password, newKey: connection.credentialKey,
                    oldKey: keyChanged ? previous?.credentialKey : nil)
        }

        // Key passphrase follows the password rules: nil keeps what is stored, "" clears it, and a
        // moved credentialKey migrates it so an edited host/user doesn't orphan the secret.
        if let keyPassphrase, keyPassphrase.isEmpty {
            keychain.removeCredential(host: connection.keyPassphraseKey)
            if keyChanged, let previous { keychain.removeCredential(host: previous.keyPassphraseKey) }
        } else {
            migrate(secret: keyPassphrase, newKey: connection.keyPassphraseKey,
                    oldKey: keyChanged ? previous?.keyPassphraseKey : nil)
        }

        if let deniedStatus { return .denied(status: deniedStatus) }
        if let failedStatus { return .failed(status: failedStatus) }
        return .stored
    }

    public func remove(_ id: UUID) {
        lock.lock()
        var list = (try? JSONDecoder().decode([SFTPConnection].self,
                                              from: (try? Data(contentsOf: fileURL)) ?? Data())) ?? []
        let gone = list.first { $0.id == id }
        list.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
        lock.unlock()
        if let gone {
            keychain.removeCredential(host: gone.credentialKey)
            keychain.removeCredential(host: gone.keyPassphraseKey)
        }
    }

    /// The stored password, if any. A Keychain refusal is indistinguishable from "none stored" — use
    /// ``passwordLookup(for:)`` when that matters (it does before reporting an auth failure).
    public func password(for connection: SFTPConnection) -> String? {
        passwordLookup(for: connection).password
    }

    /// The stored passphrase for the connection's private key, if any.
    public func keyPassphrase(for connection: SFTPConnection) -> String? {
        keyPassphraseLookup(for: connection).password
    }

    /// The stored password including *why* it is missing, so a denied Keychain prompt can be reported
    /// and retried instead of being mistaken for a wrong password.
    public func passwordLookup(for connection: SFTPConnection) -> CredentialLookup {
        keychain.lookupCredential(forHost: connection.credentialKey)
    }

    /// The key passphrase including *why* it is missing. See ``passwordLookup(for:)``.
    public func keyPassphraseLookup(for connection: SFTPConnection) -> CredentialLookup {
        keychain.lookupCredential(forHost: connection.keyPassphraseKey)
    }

    /// Password lookup by the `user@host:port` key (used by the engine when it
    /// only has an `sftp://` URL to work from).
    public func password(user: String, host: String, port: Int) -> String? {
        keychain.credential(forHost: "\(user)@\(host):\(port)")?.password
    }
}
