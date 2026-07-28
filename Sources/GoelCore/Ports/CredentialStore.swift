import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Glibc)
import Glibc
#endif

public protocol CredentialProviding: Sendable {
    func basicAuthorization(forHost host: String) -> String?
}

public protocol CredentialManaging: Sendable {
    func credential(forHost host: String) -> (username: String, password: String)?
    @discardableResult func setCredential(username: String, password: String, host: String) -> Bool
    @discardableResult func removeCredential(host: String) -> Bool
    func allCredentials() -> [HostCredential]

    func lookupCredential(forHost host: String) -> CredentialLookup
    @discardableResult
    func storeCredential(username: String, password: String, host: String) -> CredentialWrite
}

/// Never collapse these to nil: a denied Keychain prompt would read as "no password saved".
public enum CredentialLookup: Sendable, Equatable {
    case found(username: String, password: String)
    case notFound
    case denied(status: Int32)
    case failed(status: Int32)

    public var password: String? {
        if case .found(_, let password) = self { return password }
        return nil
    }
    public var isRetryable: Bool {
        if case .denied = self { return true }
        return false
    }

    public var statusDetail: String? {
        switch self {
        case .found, .notFound: return nil
        case .denied(let s): return "Keychain denied access (OSStatus \(s))"
        case .failed(let s): return "Keychain read failed (OSStatus \(s))"
        }
    }
}

public enum CredentialWrite: Sendable, Equatable {
    case stored
    case denied(status: Int32)
    case failed(status: Int32)

    public var didStore: Bool { self == .stored }
    public var isRetryable: Bool {
        if case .denied = self { return true }
        return false
    }

    public var statusDetail: String? {
        switch self {
        case .stored: return nil
        case .denied(let s): return "Keychain denied access (OSStatus \(s))"
        case .failed(let s): return "Keychain write failed (OSStatus \(s))"
        }
    }
}

public extension CredentialManaging {
    func lookupCredential(forHost host: String) -> CredentialLookup {
        guard let c = credential(forHost: host) else { return .notFound }
        return .found(username: c.username, password: c.password)
    }

    @discardableResult
    func storeCredential(username: String, password: String, host: String) -> CredentialWrite {
        setCredential(username: username, password: password, host: host)
            ? .stored : .failed(status: 0)
    }
}

public struct HostCredential: Codable, Sendable, Hashable, Identifiable {
    public var id: String { host }
    public var host: String
    public var username: String

    public init(host: String, username: String) {
        self.host = host
        self.username = username
    }
}

public final class KeychainCredentialStore: CredentialProviding, CredentialManaging, @unchecked Sendable {

    private let label = "GoelDownloader"

    public init() {}

    public func basicAuthorization(forHost host: String) -> String? {
        guard !host.isEmpty, let (user, password) = credential(forHost: host) else { return nil }
        let raw = Data("\(user):\(password)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }

    #if canImport(Security)

    /// A *cancelled* prompt must stay out of this list — re-issuing it loops.
    private static func isTransient(_ status: OSStatus) -> Bool {
        status == errSecNotAvailable || status == errSecInteractionNotAllowed
    }

    private static func isDenial(_ status: OSStatus) -> Bool {
        status == errSecUserCanceled || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed || status == errSecNotAvailable
    }

    /// Bounded at 3 attempts / ~120 ms — callers may be on the main thread.
    private func withRetry(attempts: Int = 3, _ operation: () -> OSStatus) -> OSStatus {
        var status = operation()
        var delay = 0.04
        var remaining = attempts - 1
        while remaining > 0, Self.isTransient(status) {
            Thread.sleep(forTimeInterval: delay)
            delay *= 2
            status = operation()
            remaining -= 1
        }
        return status
    }

    public func credential(forHost host: String) -> (username: String, password: String)? {
        guard case .found(let user, let password) = lookupCredential(forHost: host) else { return nil }
        return (user, password)
    }

    public func lookupCredential(forHost host: String) -> CredentialLookup {
        var query = baseQuery(host: host)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = withRetry { SecItemCopyMatching(query as CFDictionary, &item) }
        switch status {
        case errSecSuccess:
            guard let dict = item as? [String: Any],
                  let account = dict[kSecAttrAccount as String] as? String,
                  let data = dict[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                return .failed(status: Int32(status))
            }
            return .found(username: account, password: password)
        case errSecItemNotFound:
            return .notFound
        default:
            return Self.isDenial(status) ? .denied(status: Int32(status))
                                         : .failed(status: Int32(status))
        }
    }

    @discardableResult
    public func setCredential(username: String, password: String, host: String) -> Bool {
        storeCredential(username: username, password: password, host: host).didStore
    }

    @discardableResult
    public func storeCredential(username: String, password: String, host: String) -> CredentialWrite {
        // Update-then-add, never delete-then-add: a refused `SecItemAdd` would wipe a working password.
        let base = baseQuery(host: host)
        let changes: [String: Any] = [
            kSecAttrAccount as String: username,
            kSecValueData as String: Data(password.utf8),
        ]
        var status = withRetry { SecItemUpdate(base as CFDictionary, changes as CFDictionary) }
        if status == errSecItemNotFound {
            var attributes = base
            attributes[kSecAttrAccount as String] = username
            attributes[kSecValueData as String] = Data(password.utf8)
            status = withRetry { SecItemAdd(attributes as CFDictionary, nil) }
        }
        switch status {
        case errSecSuccess: return .stored
        default:
            return Self.isDenial(status) ? .denied(status: Int32(status))
                                         : .failed(status: Int32(status))
        }
    }

    @discardableResult
    public func removeCredential(host: String) -> Bool {
        withRetry { SecItemDelete(baseQuery(host: host) as CFDictionary) } == errSecSuccess
    }

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

    private static let fileLock = NSLock()

    private struct Entry: Codable { var username: String; var password: String }

    /// An unreadable file must NOT be overwritten, or every stored credential is silently lost.
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
            GoelLog.persistence.error("Credentials file unreadable — leaving it untouched",
                                      .path(storeURL.path))
            return .unreadable
        }
        return .ok(dict)
    }

    private func save(_ dict: [String: Entry]) -> Bool {
        let url = storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        #if canImport(Glibc)
        // Creates the atomic temp file 0600 from birth: no world-readable window before the chmod.
        let previousMask = umask(0o077)
        defer { umask(previousMask) }
        #endif
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            GoelLog.persistence.error("Failed to write credentials", .detail(String(describing: error)))
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
           mode.intValue & 0o077 != 0 {
            GoelLog.persistence.fault("Credentials file is not private",
                                      .state(String(mode.intValue, radix: 8), label: "mode"))
        }
        return true
    }

    public func credential(forHost host: String) -> (username: String, password: String)? {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        guard case .ok(let dict) = loadState(), let e = dict[host] else { return nil }
        return (e.username, e.password)
    }

    /// Overrides the default bridge so an unreadable store reports `.failed`, not `.notFound`.
    public func lookupCredential(forHost host: String) -> CredentialLookup {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        switch loadState() {
        case .ok(let dict):
            guard let e = dict[host] else { return .notFound }
            return .found(username: e.username, password: e.password)
        case .missing:
            return .notFound
        case .unreadable:
            return .failed(status: -1)
        }
    }

    @discardableResult
    public func storeCredential(username: String, password: String, host: String) -> CredentialWrite {
        setCredential(username: username, password: password, host: host)
            ? .stored : .failed(status: -1)
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
