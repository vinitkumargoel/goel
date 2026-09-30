import Foundation

/// Caps open connections overall and per peer, so one address trickling requests cannot take
/// every slot. Lock-based and synchronous: NIO handlers call it on the event loop, off any actor.
final class RemoteConnectionGate: @unchecked Sendable {
    static let defaultLimit = 32
    static let defaultPerClientLimit = 8

    private let lock = NSLock()
    private let limit: Int
    private let perClientLimit: Int
    private var total = 0
    private var byClient: [String: Int] = [:]

    init(limit: Int = defaultLimit, perClientLimit: Int = defaultPerClientLimit) {
        self.limit = limit
        self.perClientLimit = perClientLimit
    }

    /// Loopback is exempt from the per-peer cap: a same-host reverse proxy carries every user.
    func tryAcquire(client: String) -> Bool {
        let key = Self.key(client)
        lock.lock(); defer { lock.unlock() }
        guard total < limit else { return false }
        let current = byClient[key] ?? 0
        if !Self.isLoopback(key), current >= perClientLimit { return false }
        total += 1
        byClient[key] = current + 1
        return true
    }

    func release(client: String) {
        let key = Self.key(client)
        lock.lock(); defer { lock.unlock() }
        guard let current = byClient[key] else { return }
        total = max(0, total - 1)
        byClient[key] = current > 1 ? current - 1 : nil
    }

    var openCount: Int { lock.lock(); defer { lock.unlock() }; return total }

    private static func key(_ client: String) -> String {
        let normalised = IPMatcher.normalise(client)
        return normalised.isEmpty ? "unknown" : normalised
    }

    private static func isLoopback(_ key: String) -> Bool {
        key == "::1" || key.hasPrefix("127.")
    }
}
