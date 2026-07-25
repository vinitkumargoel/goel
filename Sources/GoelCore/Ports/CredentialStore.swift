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

    /// Read `host`'s credential, distinguishing "nothing stored" from "we were
    /// not allowed to look". See ``CredentialLookup``.
    func lookupCredential(forHost host: String) -> CredentialLookup
    /// Write `host`'s credential, reporting refusal separately from failure.
    @discardableResult
    func storeCredential(username: String, password: String, host: String) -> CredentialWrite
}

/// The result of reading a stored secret.
///
/// This exists because collapsing every failure to `nil` is actively harmful:
/// a denied Keychain prompt then looks identical to "no password saved", so the
/// connection proceeds with no credential and the server's rejection is reported
/// as a wrong password. The user is sent to re-type a password that was never
/// the problem. ``denied`` is retryable — the prompt can be presented again.
public enum CredentialLookup: Sendable, Equatable {
    case found(username: String, password: String)
    /// Definitively no entry for this host.
    case notFound
    /// The keychain refused: user cancelled the prompt, or it is locked.
    case denied(status: Int32)
    /// Something else went wrong (malformed item, unexpected status).
    case failed(status: Int32)

    /// The secret when one was actually read, else nil. For call sites that
    /// genuinely cannot act on the distinction.
    public var password: String? {
        if case .found(_, let password) = self { return password }
        return nil
    }
    /// Whether presenting the prompt again could succeed.
    public var isRetryable: Bool {
        if case .denied = self { return true }
        return false
    }

    /// The raw status, for the "Technical detail" disclosure.
    public var statusDetail: String? {
        switch self {
        case .found, .notFound: return nil
        case .denied(let s): return "Keychain denied access (OSStatus \(s))"
        case .failed(let s): return "Keychain read failed (OSStatus \(s))"
        }
    }
}

/// The result of writing a stored secret. ``denied`` is retryable.
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
    /// Default bridge for stores with no richer notion of refusal (the Linux
    /// file backend, in-memory fakes): absence is simply `notFound`.
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

    /// Statuses worth retrying automatically: the keychain is momentarily locked
    /// or unavailable (right after wake, or mid-unlock) and the same call a
    /// moment later usually succeeds.
    ///
    /// A user *cancelling* the prompt is deliberately excluded — re-issuing the
    /// request would re-prompt in a loop and harass them. That surfaces as
    /// ``CredentialLookup/denied`` so the UI can offer one explicit Retry.
    private static func isTransient(_ status: OSStatus) -> Bool {
        status == errSecNotAvailable || status == errSecInteractionNotAllowed
    }

    /// Statuses that mean "refused, but asking again could work".
    private static func isDenial(_ status: OSStatus) -> Bool {
        status == errSecUserCanceled || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed || status == errSecNotAvailable
    }

    /// Run a keychain call, retrying transient refusals with a short backoff.
    /// Bounded at 3 attempts / ~120 ms so a caller on the main thread can't stall
    /// perceptibly.
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

    /// The username + password stored for `host`, or nil. Prefer
    /// ``lookupCredential(forHost:)`` where a refusal must be distinguished
    /// from an absent entry.
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

    /// Insert or replace the credential for `host`.
    @discardableResult
    public func setCredential(username: String, password: String, host: String) -> Bool {
        storeCredential(username: username, password: password, host: host).didStore
    }

    @discardableResult
    public func storeCredential(username: String, password: String, host: String) -> CredentialWrite {
        // Update-then-add, never delete-then-add. The old form deleted the
        // existing item first, so a refused or failed `SecItemAdd` destroyed the
        // stored password outright — a denied Keychain prompt silently wiped a
        // working credential.
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
        // Keeps the documented "existed and was removed" semantics (so
        // `errSecItemNotFound` is false, matching the Linux backend); the retry
        // only covers a momentarily locked keychain.
        withRetry { SecItemDelete(baseQuery(host: host) as CFDictionary) } == errSecSuccess
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
            GoelLog.persistence.error("Credentials file unreadable — leaving it untouched",
                                      .path(storeURL.path))
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
            GoelLog.persistence.error("Failed to write credentials", .detail(String(describing: error)))
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
           mode.intValue & 0o077 != 0 {
            // The permission bits are a property of the machine, not of the user's
            // activity, so the octal mode stays public — it is the whole point of
            // the warning that an operator can read it out of the log.
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

    /// Explicit override so a *present but unreadable* store reports `.failed`
    /// rather than the default bridge's `.notFound` — otherwise a corrupt or
    /// permission-denied file looks exactly like "no password saved", which is
    /// the same misdiagnosis the macOS path guards against.
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
