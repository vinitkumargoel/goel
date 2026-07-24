import Foundation

/// Persists the user's saved SFTP servers: the list (minus secrets) as JSON in
/// Application Support, and each password in the Keychain. Thread-safe.
public final class SFTPConnectionStore: @unchecked Sendable {

    public static let shared = SFTPConnectionStore()

    /// Injected credential store (the ``CredentialManaging`` port) and, for tests,
    /// an override base directory. Both default to production behaviour so
    /// `SFTPConnectionStore()` and `.shared` are unchanged.
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

    /// Insert or replace a connection, storing its password in the Keychain.
    /// A nil `password` leaves any existing secret untouched (edit without
    /// retyping); an empty string clears it.
    ///
    /// Returns what happened to the *secrets*. The connection list itself is
    /// plain JSON and always persists; only the Keychain half can be refused, and
    /// a refusal is retryable — callers should surface it rather than reporting
    /// a successful save the user cannot rely on.
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

        // The Keychain is keyed by `credentialKey` (user@host:port), which is
        // derived from mutable fields. When editing changes any of them the key
        // moves, so we must keep the secret with the connection under its new key
        // and delete the stale one — otherwise blank-password edits (the "keep
        // the stored one" path) orphan the secret and silently break the login.
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

        /// Write `secret` under the connection's key, and only drop the stale
        /// entry once the new one is definitely in place. Deleting first (or
        /// unconditionally) means a refused Keychain prompt destroys the sole
        /// copy of a working secret.
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

        // The key passphrase follows the same rules as the password: nil keeps
        // whatever is stored, "" clears it, and a moved credentialKey migrates it
        // so an edited host/user doesn't orphan the secret.
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

    /// The stored password for a connection, if any. A Keychain refusal is
    /// indistinguishable from "none stored" here — use ``passwordLookup(for:)``
    /// when that difference matters (it does before reporting an auth failure).
    public func password(for connection: SFTPConnection) -> String? {
        passwordLookup(for: connection).password
    }

    /// The stored passphrase for the connection's private key, if any.
    public func keyPassphrase(for connection: SFTPConnection) -> String? {
        keyPassphraseLookup(for: connection).password
    }

    /// The stored password including *why* it is missing, so a denied Keychain
    /// prompt can be reported and retried instead of being mistaken for a wrong
    /// password.
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
