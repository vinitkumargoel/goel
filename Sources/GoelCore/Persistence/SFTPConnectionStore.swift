import Foundation

/// Persists the user's saved SFTP servers: the list (minus secrets) as JSON in
/// Application Support, and each password in the Keychain. Thread-safe.
public final class SFTPConnectionStore: @unchecked Sendable {

    public static let shared = SFTPConnectionStore()

    private let keychain = KeychainCredentialStore()
    private let lock = NSLock()

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("GoelDownloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sftp-connections.json")
    }

    public init() {}

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
        if let idx = list.firstIndex(where: { $0.id == connection.id }) {
            list[idx] = connection
        } else {
            list.append(connection)
        }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
        lock.unlock()

        if let password {
            keychain.setCredential(username: connection.username,
                                   password: password,
                                   host: connection.credentialKey)
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
