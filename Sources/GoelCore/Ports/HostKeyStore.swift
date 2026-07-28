import Foundation

/// `known_hosts` semantics for SSH host keys: pin on first contact, refuse mismatches, fail closed.
public final class HostKeyStore: @unchecked Sendable {

    /// `.unavailable` must stay distinct from `.none`: a read failure read as "no pin" re-arms TOFU.
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

    /// The C shim skips verification entirely on an empty `expected_fp`, so reject anything malformed.
    private static func isValidFingerprint(_ fingerprint: String) -> Bool {
        fingerprint.count == 64 && fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// nil = untrustworthy record; only a genuinely absent key may return an empty map.
    private func all() -> [String: String]? {
        guard let raw = defaults.object(forKey: key) else { return [:] }
        guard let map = raw as? [String: String],
              map.values.allSatisfy(Self.isValidFingerprint) else { return nil }
        return map
    }

    /// Every trust decision must go through this, never ``fingerprint(host:port:)``.
    public func lookup(host: String, port: Int) -> PinLookup {
        lock.lock(); defer { lock.unlock() }
        guard let map = all() else { return .unavailable }
        guard let pinned = map[Self.slot(host: host, port: port)] else { return .none }
        return .pinned(pinned)
    }

    /// Display only: this collapses "never connected" and "unreadable" into nil, so it cannot gate trust.
    public func fingerprint(host: String, port: Int) -> String? {
        guard case .pinned(let pinned) = lookup(host: host, port: port) else { return nil }
        return pinned
    }

    /// Writes nothing on an unreadable record — saving a map we failed to read drops every other pin.
    @discardableResult
    public func setFingerprint(_ fingerprint: String, host: String, port: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValidFingerprint(fingerprint), var map = all() else { return false }
        map[Self.slot(host: host, port: port)] = fingerprint
        defaults.set(map, forKey: key)
        return true
    }

    /// Discarding an unreadable record whole is the only escape from a store that refuses every connection.
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
