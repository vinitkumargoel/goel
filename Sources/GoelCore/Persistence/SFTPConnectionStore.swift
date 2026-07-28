import Foundation

public final class SFTPConnectionStore: @unchecked Sendable {

    public static let shared = SFTPConnectionStore()

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

    public func load() -> [SFTPConnection] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([SFTPConnection].self, from: data) else {
            return []
        }
        return list
    }

    /// nil `password` keeps the stored secret; "" clears it. Same rule for `keyPassphrase`.
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

        // `credentialKey` is built from mutable fields, so an edit moves it — migrate or orphan the secret.
        let keyChanged = previous.map { $0.credentialKey != connection.credentialKey } ?? false

        var deniedStatus: Int32?
        var failedStatus: Int32?
        func note(_ write: CredentialWrite) {
            switch write {
            case .stored: break
            case .denied(let s): deniedStatus = deniedStatus ?? s
            case .failed(let s): failedStatus = failedStatus ?? s
            }
        }

        /// Store then delete, never the reverse: a refused Keychain prompt would destroy the only copy.
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
            guard let oldKey, oldKey != newKey else { return }
            switch keychain.lookupCredential(forHost: oldKey) {
            case .found(_, let stored):
                let write = keychain.storeCredential(username: connection.username,
                                                     password: stored, host: newKey)
                note(write)
                if write.didStore { keychain.removeCredential(host: oldKey) }
            case .notFound:
                break
            // Old secret unreadable: report it, but do NOT delete — it is the only copy.
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

    /// A Keychain refusal is indistinguishable from "none stored" — use ``passwordLookup(for:)``.
    public func password(for connection: SFTPConnection) -> String? {
        passwordLookup(for: connection).password
    }

    public func keyPassphrase(for connection: SFTPConnection) -> String? {
        keyPassphraseLookup(for: connection).password
    }

    public func passwordLookup(for connection: SFTPConnection) -> CredentialLookup {
        keychain.lookupCredential(forHost: connection.credentialKey)
    }

    public func keyPassphraseLookup(for connection: SFTPConnection) -> CredentialLookup {
        keychain.lookupCredential(forHost: connection.keyPassphraseKey)
    }

    public func password(user: String, host: String, port: Int) -> String? {
        keychain.credential(forHost: "\(user)@\(host):\(port)")?.password
    }
}
