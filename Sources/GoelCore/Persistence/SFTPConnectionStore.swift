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
    public func save(_ connection: SFTPConnection, password: String?) {
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
        if let password {
            keychain.setCredential(username: connection.username,
                                   password: password,
                                   host: connection.credentialKey)
            if keyChanged, let previous { keychain.removeCredential(host: previous.credentialKey) }
        } else if keyChanged, let previous,
                  let stored = keychain.credential(forHost: previous.credentialKey) {
            // Password left unchanged but the key moved: migrate the stored secret.
            keychain.setCredential(username: connection.username,
                                   password: stored.password,
                                   host: connection.credentialKey)
            keychain.removeCredential(host: previous.credentialKey)
        }
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
        if let gone { keychain.removeCredential(host: gone.credentialKey) }
    }

    /// The stored password for a connection, if any.
    public func password(for connection: SFTPConnection) -> String? {
        keychain.credential(forHost: connection.credentialKey)?.password
    }

    /// Password lookup by the `user@host:port` key (used by the engine when it
    /// only has an `sftp://` URL to work from).
    public func password(user: String, host: String, port: Int) -> String? {
        keychain.credential(forHost: "\(user)@\(host):\(port)")?.password
    }
}
