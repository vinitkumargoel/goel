import Foundation

// MARK: - Cross-download connection budget

/// Thin wrappers that delegate to ``connectionBudget``. The byte-moving
/// mechanics live in ``SegmentedTransfer`` / ``PlannedTransfer``; what stays
/// here needs the engine's aggregate state on the actor.
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

    // MARK: Segment count

    /// The connection count this download may open, drawn from the cross-download
    /// budget. ``SegmentedTransfer`` applies the remaining (size-only) clamp.
    func resolveSegmentCount(total: Int64, host: String?) -> Int {
        connectionBudget.resolveSegmentCount(total: total, host: host, profile: profile)
    }
}
