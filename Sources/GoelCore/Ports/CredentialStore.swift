import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Glibc)
import Glibc   // umask, for creating the Linux secrets file privately
#endif

// MARK: - Per-host download credentials

/// Supplies the `Authorization` header value for a host, if the user has
/// stored credentials for it. Injected into ``HTTPEngine`` so protected
/// direct downloads authenticate preemptively (HTTP Basic).
public protocol CredentialProviding: Sendable {
    func basicAuthorization(forHost host: String) -> String?
}

/// The credential *management* surface (create / read / delete / list), behind a
/// protocol so consumers like ``SFTPConnectionStore`` and the settings pane depend
/// on the port and can inject an in-memory fake instead of hard-instantiating the
/// Keychain/file-backed concrete store. ``CredentialProviding`` is the read-only
/// preemptive-Basic seam injected into ``HTTPEngine``; this is its management
/// counterpart. The Keychain (macOS) vs `0600`-file (Linux) split stays hidden
/// behind the port.
public protocol CredentialManaging: Sendable {
    /// The username + password stored for `host`, or nil.
    func credential(forHost host: String) -> (username: String, password: String)?
    /// Insert or replace the credential for `host`. Returns whether it persisted.
    @discardableResult func setCredential(username: String, password: String, host: String) -> Bool
    /// Remove the credential for `host`. Returns whether one existed and was removed.
    @discardableResult func removeCredential(host: String) -> Bool
    /// Every host with a stored credential (no secrets), for the management UI.
    func allCredentials() -> [HostCredential]
}

/// A stored entry, minus the secret (for the management UI's list).
public struct HostCredential: Codable, Sendable, Hashable, Identifiable {
    public var id: String { host }
    public var host: String
    public var username: String

    public init(host: String, username: String) {
        self.host = host
        self.username = username
    }
}

/// Per-host credential storage keyed by server host.
///
/// On macOS this is Keychain-backed (`kSecClassInternetPassword`); on Linux it is
/// a `0600` JSON file under the user's config dir. The name is kept
/// (`KeychainCredentialStore`) so call sites don't change; secrets are only ever
/// read to build the `Authorization` header.
public final class KeychainCredentialStore: CredentialProviding, CredentialManaging, @unchecked Sendable {

    /// The service label distinguishing our items from other apps' entries.
    private let label = "GoelDownloader"

    public init() {}

    // MARK: CredentialProviding

    public func basicAuthorization(forHost host: String) -> String? {
        guard !host.isEmpty, let (user, password) = credential(forHost: host) else { return nil }
        let raw = Data("\(user):\(password)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }

    #if canImport(Security)

    // MARK: Management (macOS / Keychain)

    /// The username + password stored for `host`, or nil.
    public func credential(forHost host: String) -> (username: String, password: String)? {
        var query = baseQuery(host: host)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String,
              let data = dict[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return (account, password)
    }

    /// Insert or replace the credential for `host`.
    @discardableResult
    public func setCredential(username: String, password: String, host: String) -> Bool {
        removeCredential(host: host)
        var attributes = baseQuery(host: host)
        attributes[kSecAttrAccount as String] = username
        attributes[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func removeCredential(host: String) -> Bool {
        SecItemDelete(baseQuery(host: host) as CFDictionary) == errSecSuccess
    }

    /// Every host we hold a credential for (no secrets), for the settings list.
    public func allCredentials() -> [HostCredential] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let dicts = items as? [[String: Any]] else { return [] }
        return dicts.compactMap { dict in
            guard let host = dict[kSecAttrServer as String] as? String,
                  let account = dict[kSecAttrAccount as String] as? String else { return nil }
            return HostCredential(host: host, username: account)
        }
        .sorted { $0.host < $1.host }
    }

    private func baseQuery(host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrLabel as String: label,
        ]
    }

    #else

    // MARK: Management (Linux / 0600 JSON file)

    /// Serializes file access; the macOS Keychain was already thread-safe.
    private static let fileLock = NSLock()

    private struct Entry: Codable { var username: String; var password: String }

    /// Distinguishes "no file yet" (fine) from "file present but unreadable"
    /// (must NOT be overwritten, or every stored credential is silently lost).
    private enum LoadResult {
        case ok([String: Entry])
        case missing
        case unreadable
    }

    private var storeURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("goel-downloader/credentials.json")
    }

    private func loadState() -> LoadResult {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            FileHandle.standardError.write(Data(
                "[GoelDownloader] credentials file unreadable at \(storeURL.path) — leaving it untouched\n".utf8))
            return .unreadable
        }
        return .ok(dict)
    }

    /// Persist the store; returns whether it actually reached disk. Reports the
    /// real outcome (unlike the always-`true` stub this replaced) so a disk-full /
    /// read-only-config failure is diagnosable instead of silently swallowed.
    private func save(_ dict: [String: Entry]) -> Bool {
        let url = storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        #if canImport(Glibc)
        // Tighten the umask so the atomic temp file is created 0600 from birth —
        // no world-readable window between the write and the chmod below.
        let previousMask = umask(0o077)
        defer { umask(previousMask) }
        #endif
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[GoelDownloader] failed to write credentials: \(error)\n".utf8))
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
           mode.intValue & 0o077 != 0 {
            FileHandle.standardError.write(Data(
                "[GoelDownloader] WARNING credentials file is not private (mode \(String(mode.intValue, radix: 8)))\n".utf8))
        }
        return true
    }

    public func credential(forHost host: String) -> (username: String, password: String)? {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        guard case .ok(let dict) = loadState(), let e = dict[host] else { return nil }
        return (e.username, e.password)
    }

    @discardableResult
    public func setCredential(username: String, password: String, host: String) -> Bool {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        var dict: [String: Entry]
        switch loadState() {
        case .ok(let d): dict = d
        case .missing: dict = [:]
        case .unreadable: return false   // refuse to clobber an existing store we couldn't read
        }
        dict[host] = Entry(username: username, password: password)
        return save(dict)
    }

    @discardableResult
    public func removeCredential(host: String) -> Bool {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        guard case .ok(var dict) = loadState() else { return false }
        guard dict.removeValue(forKey: host) != nil else { return false }
        return save(dict)
    }

    public func allCredentials() -> [HostCredential] {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        guard case .ok(let dict) = loadState() else { return [] }
        return dict.map { HostCredential(host: $0.key, username: $0.value.username) }
            .sorted { $0.host < $1.host }
    }

    #endif
}
