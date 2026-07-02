import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - Per-host download credentials

/// Supplies the `Authorization` header value for a host, if the user has
/// stored credentials for it. Injected into ``HTTPEngine`` so protected
/// direct downloads authenticate preemptively (HTTP Basic).
public protocol CredentialProviding: Sendable {
    func basicAuthorization(forHost host: String) -> String?
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
public final class KeychainCredentialStore: CredentialProviding, @unchecked Sendable {

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

    private var storeURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("goel-downloader/credentials.json")
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return dict
    }

    private func save(_ dict: [String: Entry]) {
        let url = storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(dict) else { return }
        // Write then clamp to 0600 so the secrets file isn't world-readable.
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func credential(forHost host: String) -> (username: String, password: String)? {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        guard let e = load()[host] else { return nil }
        return (e.username, e.password)
    }

    @discardableResult
    public func setCredential(username: String, password: String, host: String) -> Bool {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        var dict = load()
        dict[host] = Entry(username: username, password: password)
        save(dict)
        return true
    }

    @discardableResult
    public func removeCredential(host: String) -> Bool {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        var dict = load()
        guard dict.removeValue(forKey: host) != nil else { return false }
        save(dict)
        return true
    }

    public func allCredentials() -> [HostCredential] {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        return load().map { HostCredential(host: $0.key, username: $0.value.username) }
            .sorted { $0.host < $1.host }
    }

    #endif
}

/// Session delegate stripping the manually-attached `Authorization` header
/// when a redirect crosses to a different host — Foundation doesn't scope a
/// hand-set header to a protection space, so without this a mirror redirect
/// could carry the user's Basic credentials to an arbitrary third party.
public final class RedirectSanitizer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    public static let shared = RedirectSanitizer()

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        var sanitized = request
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        let downgradedToHTTP = request.url?.scheme?.lowercased() != "https"
        if sanitized.value(forHTTPHeaderField: "Authorization") != nil,
           originalHost != newHost || downgradedToHTTP {
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(sanitized)
    }
}
