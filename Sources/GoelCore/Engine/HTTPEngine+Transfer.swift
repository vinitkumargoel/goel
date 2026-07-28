import Foundation

/// Grants recorded outside the actor: the closure is `@Sendable` while the balancing defer is actor-isolated; the lock bridges them.
final class ExtraGrantCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { guard n > 0 else { return }; lock.lock(); count += n; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}

extension HTTPEngine {
    func reserveConnections(host: String?, count: Int) {
        connectionBudget.reserve(host: host, count: count)
    }

    func releaseConnections(host: String?, count: Int) {
        connectionBudget.release(host: host, count: count)
    }

    /// Raw room, no floor-of-1: the download already holds a connection, so 0 is honest — the planner's floor is for NEW ones.
    func grantExtraConnections(host: String?, wanted: Int) -> Int {
        let grant = min(max(0, wanted), connectionBudget.extraRoom(host: host, profile: profile))
        guard grant > 0 else { return 0 }
        connectionBudget.reserve(host: host, count: grant)
        return grant
    }

    func resolveSegmentCount(total: Int64, host: String?) -> Int {
        connectionBudget.resolveSegmentCount(total: total, host: host, profile: profile)
    }
}
