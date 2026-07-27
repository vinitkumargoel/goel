import Foundation

/// Lightweight browser-session state kept separately from an SFTP connection's
/// configured start folder. One last-known-good directory is retained per server.
final class SFTPBrowserLocationStore: @unchecked Sendable {
    static let shared = SFTPBrowserLocationStore()

    private let defaults: UserDefaults
    private let key = "GoelDownloader.SFTPBrowserLastFolders"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func path(for connectionID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return locations()[connectionID.uuidString]
    }

    func setPath(_ path: String, for connectionID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var saved = locations()
        saved[connectionID.uuidString] = path.isEmpty ? "." : path
        defaults.set(saved, forKey: key)
    }

    func removePath(for connectionID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var saved = locations()
        saved.removeValue(forKey: connectionID.uuidString)
        defaults.set(saved, forKey: key)
    }

    /// Browser locations are disposable UI state. A malformed preference falls
    /// back to an empty map rather than blocking access to configured servers.
    private func locations() -> [String: String] {
        guard let raw = defaults.object(forKey: key) else { return [:] }
        return raw as? [String: String] ?? [:]
    }
}
