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

/// Session delegate stripping manually-attached credential/context headers when a
/// redirect crosses to a different host — Foundation doesn't scope a hand-set
/// header to a protection space, so without this a redirect could carry the
/// user's Basic credentials, `Referer`, `Cookie`, or any custom auth header to an
/// arbitrary third party.
public final class RedirectSanitizer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    public static let shared = RedirectSanitizer()

    /// Headers safe to carry across a host change / scheme downgrade because they
    /// describe the client and transport, not the user's authorization to one
    /// origin. Everything else on the original request — `Authorization`,
    /// `Cookie`, `Referer`, AND any custom per-task header the user attached for
    /// the original host (e.g. `X-Api-Key`, `PRIVATE-TOKEN`, `X-Auth-Token`) — is a
    /// secret scoped to that host and must be dropped, not just the three we can
    /// name. Allow-list (not a deny-list) so a header we've never heard of is
    /// treated as sensitive by default.
    static let crossHostSafeHeaders: Set<String> = [
        "user-agent", "accept", "accept-encoding", "accept-language",
        "range", "if-range",
    ]

    /// Strip every origin-scoped header from `request` when a redirect crosses to
    /// a different host (relative to `originalURL`) or downgrades https→http. Shared
    /// by this session-level delegate and the per-task `ChunkStreamer`/auto-fetch
    /// delegates (which supersede it for their task). Takes the original URL rather
    /// than the task so it is directly unit-testable.
    static func sanitize(_ request: URLRequest, originalURL: URL?) -> URLRequest {
        var sanitized = request
        let originalHost = originalURL?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        let downgradedToHTTP = (request.url?.scheme?.lowercased() != "https")
        guard originalHost != newHost || downgradedToHTTP else { return sanitized }
        for name in (request.allHTTPHeaderFields ?? [:]).keys
        where !crossHostSafeHeaders.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.sanitize(request, originalURL: task.originalRequest?.url))
    }
}
