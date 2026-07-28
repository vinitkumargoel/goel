import Foundation

// MARK: - Cross-download connection budget

/// Mid-flight grants recorded outside the actor: the closure is @Sendable while
/// the balancing defer runs actor-isolated; the lock is the bridge.
final class ExtraGrantCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { guard n > 0 else { return }; lock.lock(); count += n; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Thin wrappers delegating to ``connectionBudget``. Byte-moving lives in ``SegmentedTransfer`` /
/// ``PlannedTransfer``; what stays here needs the engine's aggregate state on the actor.
extension HTTPEngine {

    // MARK: Connection budget

    /// Charge `count` connections to the global and per-host budgets when a
    /// download's segments start. Balanced by `releaseConnections`.
    func reserveConnections(host: String?, count: Int) {
        connectionBudget.reserve(host: host, count: count)
    }

    /// Return `count` connections to the budgets when a download ends (cleanly,
    /// by failure, or by pause/remove cancellation).
    func releaseConnections(host: String?, count: Int) {
        connectionBudget.release(host: host, count: count)
    }

    /// Charge up to `wanted` extra connections for a running download (W2 upgrade). Raw room, no
    /// floor-of-1: it already holds a connection, so 0 is honest — the planner's floor is for NEW ones.
    func grantExtraConnections(host: String?, wanted: Int) -> Int {
        let grant = min(max(0, wanted), connectionBudget.extraRoom(host: host, profile: profile))
        guard grant > 0 else { return 0 }
        connectionBudget.reserve(host: host, count: grant)
        return grant
    }

    // MARK: Segment count

    /// The connection count this download may open, drawn from the cross-download
    /// budget. ``SegmentedTransfer`` applies the remaining (size-only) clamp.
    func resolveSegmentCount(total: Int64, host: String?) -> Int {
        connectionBudget.resolveSegmentCount(total: total, host: host, profile: profile)
    }
}
