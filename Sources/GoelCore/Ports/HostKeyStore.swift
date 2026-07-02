import Foundation

/// Trust-on-first-use record of SSH host-key fingerprints, keyed by `host:port`.
///
/// The first time we connect to a server we *learn* its host key (SHA-256
/// fingerprint) and pin it here; every later connection REQUIRES the same key,
/// so a man-in-the-middle that swaps the key is refused (matching the classic
/// `known_hosts` model). After a legitimate server rekey the user can forget the
/// pin — "Reset pinned host key" in the connection editor calls ``reset(host:port:)``
/// — which re-arms trust-on-first-use for that host (the same recovery as
/// `ssh-keygen -R`).
public final class HostKeyStore: @unchecked Sendable {

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

    private func all() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// The pinned fingerprint for a server, or nil if we've never connected.
    public func fingerprint(host: String, port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return all()[Self.slot(host: host, port: port)]
    }

    /// Pin (or re-pin) a server's fingerprint.
    public func setFingerprint(_ fingerprint: String, host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var map = all()
        map[Self.slot(host: host, port: port)] = fingerprint
        defaults.set(map, forKey: key)
    }

    /// Forget a server's pin (e.g. after an intentional rekey).
    public func reset(host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var map = all()
        map.removeValue(forKey: Self.slot(host: host, port: port))
        defaults.set(map, forKey: key)
    }
}
