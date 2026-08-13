import Foundation

/// Why a change never reached `sftp-connections.json`. A *missing* file is not in here — that is
/// legitimately an empty list; an unreadable one is, because rewriting it would replace every
/// other saved server with the single profile being edited.
public enum SFTPStoreError: Error, Sendable, Equatable {
    case unreadable
    case writeFailed(String)
}

/// The file and the Keychain fail independently, and ``CredentialWrite`` only ever described the
/// Keychain — a caller that tells the user "saved" has to see both halves.
public enum SFTPSaveOutcome: Sendable, Equatable {
    case saved(CredentialWrite)
    /// Nothing was touched: neither the file nor the Keychain.
    case notSaved(SFTPStoreError)
}

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
        guard case .ok(let list) = readState() else { return [] }
        return list
    }

    private enum FileState {
        case ok([SFTPConnection])
        case missing
        case unreadable
    }

    /// "Not there yet" is an empty list; "there but undecodable" is not — the read-modify-write
    /// that follows would otherwise hand back a file holding only the profile being edited.
    private func readState() -> FileState {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([SFTPConnection].self, from: data) else {
            GoelLog.persistence.error("SFTP connections file unreadable — leaving it untouched",
                                      .path(url.path))
            return .unreadable
        }
        return .ok(list)
    }

    private func writeFile(_ list: [SFTPConnection]) -> SFTPStoreError? {
        do {
            try JSONEncoder().encode(list).write(to: fileURL, options: .atomic)
            return nil
        } catch {
            GoelLog.persistence.error("Failed to write SFTP connections",
                                      .detail(String(describing: error)))
            return .writeFailed(error.localizedDescription)
        }
    }

    /// Returns the entry this one replaced, or the failure that means nothing was written.
    private func upsert(_ connection: SFTPConnection) -> Result<SFTPConnection?, SFTPStoreError> {
        lock.lock(); defer { lock.unlock() }
        var list: [SFTPConnection]
        switch readState() {
        case .ok(let saved): list = saved
        case .missing: list = []
        case .unreadable: return .failure(.unreadable)
        }
        let previous = list.first { $0.id == connection.id }
        if let idx = list.firstIndex(where: { $0.id == connection.id }) {
            list[idx] = connection
        } else {
            list.append(connection)
        }
        if let failure = writeFile(list) { return .failure(failure) }
        return .success(previous)
    }

    /// Returns the entry that left the file, or the failure that means it is still in it.
    private func delete(_ id: UUID) -> Result<SFTPConnection?, SFTPStoreError> {
        lock.lock(); defer { lock.unlock() }
        var list: [SFTPConnection]
        switch readState() {
        case .ok(let saved): list = saved
        case .missing: return .success(nil)
        case .unreadable: return .failure(.unreadable)
        }
        guard let gone = list.first(where: { $0.id == id }) else { return .success(nil) }
        list.removeAll { $0.id == id }
        if let failure = writeFile(list) { return .failure(failure) }
        return .success(gone)
    }

    /// The Keychain-only view of ``saveOutcome(_:password:keyPassphrase:)``: it cannot say whether
    /// the profile itself landed, so a caller that reports "saved" must use that one instead.
    @discardableResult
    public func save(_ connection: SFTPConnection, password: String?,
                     keyPassphrase: String? = nil) -> CredentialWrite {
        guard case .saved(let write) = saveOutcome(connection, password: password,
                                                   keyPassphrase: keyPassphrase) else {
            // No Keychain call was made at all — only `didStore == false` is expressible here.
            return .failed(status: 0)
        }
        return write
    }

    /// nil `password` keeps the stored secret; "" clears it. Same rule for `keyPassphrase`.
    public func saveOutcome(_ connection: SFTPConnection, password: String?,
                            keyPassphrase: String? = nil) -> SFTPSaveOutcome {
        let previous: SFTPConnection?
        switch upsert(connection) {
        case .success(let replaced):
            previous = replaced
        // Stop before the Keychain too: migrating a secret for a profile that never landed
        // strands it under a key nothing reads.
        case .failure(let error):
            return .notSaved(error)
        }

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

        if let deniedStatus { return .saved(.denied(status: deniedStatus)) }
        if let failedStatus { return .saved(.failed(status: failedStatus)) }
        return .saved(.stored)
    }

    /// Returns the failure that means the server is still saved, or nil.
    @discardableResult
    public func remove(_ id: UUID) -> SFTPStoreError? {
        switch delete(id) {
        case .success(let gone):
            // Only once the file has lost it: wiping the secret while the profile is still
            // listed leaves a server nobody can connect to.
            if let gone {
                keychain.removeCredential(host: gone.credentialKey)
                keychain.removeCredential(host: gone.keyPassphraseKey)
            }
            return nil
        case .failure(let error):
            return error
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
