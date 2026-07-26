import Foundation

/// The record of SSH host-key fingerprints, keyed by `host:port`.
///
/// The first time we connect to a server its host key (SHA-256 fingerprint) is
/// pinned here — after the user approves it where there is a user to ask (see
/// ``HostKeyTrust``), on first contact otherwise. Every later connection REQUIRES
/// the same key, so a man-in-the-middle that swaps the key is refused (matching
/// the classic `known_hosts` model). After a legitimate server rekey the user can
/// forget the pin — "Reset pinned host key" in the connection editor calls
/// ``reset(host:port:)``, the same recovery as `ssh-keygen -R`.
///
/// Every read fails closed: an unreadable record is reported as such rather than
/// as an empty store, because "no pins" silently re-arms first contact for every
/// saved server.
public final class HostKeyStore: @unchecked Sendable {

    /// A pin lookup. A read failure must never be indistinguishable from "no
    /// pin": an empty store re-arms trust-on-first-use for every server, so one
    /// unreadable record would silently downgrade the whole list.
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

    /// The hex SHA-256 shape ``gsb_hex_sha256`` produces: 64 lowercase hex
    /// characters. Anything else is a record we can't act on — and an *empty*
    /// value is worse than useless, because the C shim skips the comparison
    /// entirely for an empty `expected_fp`, leaving the host silently unverified.
    private static func isValidFingerprint(_ fingerprint: String) -> Bool {
        fingerprint.count == 64 && fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Every pin, or nil when the stored record can't be trusted — a value that
    /// isn't a `[String: String]`, or any entry that isn't a fingerprint. Only a
    /// genuinely absent key yields an empty map.
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

    /// The pinned fingerprint for a server, for display. Collapses "never
    /// connected" and "can't read the record" into nil, so it must not be used to
    /// decide whether to trust a host — see ``lookup(host:port:)``.
    public func fingerprint(host: String, port: Int) -> String? {
        guard case .pinned(let pinned) = lookup(host: host, port: port) else { return nil }
        return pinned
    }

    /// Pin (or re-pin) a server's fingerprint. Returns false — writing nothing —
    /// when the fingerprint is malformed or the existing record is unreadable:
    /// writing back a map we failed to read would replace every other server's
    /// pin with this single entry.
    @discardableResult
    public func setFingerprint(_ fingerprint: String, host: String, port: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidFingerprint(fingerprint), var map = all() else { return false }
        map[Self.slot(host: host, port: port)] = fingerprint
        defaults.set(map, forKey: key)
        return true
    }

    /// Forget a server's pin (e.g. after an intentional rekey).
    ///
    /// When the record can't be read at all, the whole thing is discarded rather
    /// than left in place: this is the only escape from a store that now refuses
    /// every connection, and forgetting pins can only ever re-arm first-contact
    /// approval — it can never accept a key a readable pin would have refused.
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
