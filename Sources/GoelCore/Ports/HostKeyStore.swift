import Foundation

/// SSH host-key SHA-256 pins keyed by `host:port` — `known_hosts` semantics: pinned on first contact
/// (see ``HostKeyTrust``), later mismatches refused, ``reset(host:port:)`` = `ssh-keygen -R`. Fails closed.
public final class HostKeyStore: @unchecked Sendable {

    /// A pin lookup. A read failure must never look like "no pin": an empty store re-arms
    /// trust-on-first-use for every server, so one unreadable record downgrades the whole list.
    public enum PinLookup: Sendable, Equatable {
        case pinned(String)
        case none
        case unavailable
    }

    public static let shared = HostKeyStore()

    private let defaults: UserDefaults
    private let key = "GoelDownloader.SSHHostKeys"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func slot(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    /// The shape ``gsb_hex_sha256`` produces: 64 lowercase hex chars. An *empty* value is worst — the C
    /// shim skips the comparison entirely for an empty `expected_fp`, leaving the host unverified.
    private static func isValidFingerprint(_ fingerprint: String) -> Bool {
        fingerprint.count == 64 && fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Every pin, or nil when the record can't be trusted (not a `[String: String]`, or an entry that
    /// isn't a fingerprint). Only a genuinely absent key yields an empty map.
    private func all() -> [String: String]? {
        guard let raw = defaults.object(forKey: key) else { return [:] }
        guard let map = raw as? [String: String],
              map.values.allSatisfy(Self.isValidFingerprint) else { return nil }
        return map
    }

    /// Whether a server is pinned, unpinned, or unreadable. Callers making a
    /// trust decision must use this rather than ``fingerprint(host:port:)``.
    public func lookup(host: String, port: Int) -> PinLookup {
        lock.lock(); defer { lock.unlock() }
        guard let map = all() else { return .unavailable }
        guard let pinned = map[Self.slot(host: host, port: port)] else { return .none }
        return .pinned(pinned)
    }

    /// The pinned fingerprint, for display only. Collapses "never connected" and "unreadable record"
    /// into nil, so it must not decide whether to trust a host — see ``lookup(host:port:)``.
    public func fingerprint(host: String, port: Int) -> String? {
        guard case .pinned(let pinned) = lookup(host: host, port: port) else { return nil }
        return pinned
    }

    /// Pin (or re-pin) a fingerprint. Returns false, writing nothing, if it is malformed or the existing
    /// record is unreadable — writing back a map we failed to read would drop every other server's pin.
    @discardableResult
    public func setFingerprint(_ fingerprint: String, host: String, port: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidFingerprint(fingerprint), var map = all() else { return false }
        map[Self.slot(host: host, port: port)] = fingerprint
        defaults.set(map, forKey: key)
        return true
    }

    /// Forget a server's pin (e.g. after an intentional rekey). An unreadable record is discarded whole —
    /// the only escape from a store refusing every connection; forgetting only ever re-arms first contact.
    @discardableResult
    public func reset(host: String, port: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var map = all() else {
            defaults.removeObject(forKey: key)
            return true
        }
        map.removeValue(forKey: Self.slot(host: host, port: port))
        defaults.set(map, forKey: key)
        return true
    }
}
