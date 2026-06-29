import Foundation

// MARK: - Cross-download connection budget

/// The aggregate connection accounting that must span ALL concurrent downloads:
/// the global / per-host budget and the segment-count resolution that draws on
/// it. The byte-moving mechanics themselves live in ``SegmentedTransfer``; what
/// stays here needs the engine's aggregate state, so it cannot move off the actor.
extension HTTPEngine {

    // MARK: Connection budget

    /// Charge `count` connections to the global and per-host budgets when a
    /// download's segments start. Balanced by `releaseConnections`.
    func reserveConnections(host: String?, count: Int) {
        totalConnections += count
        if let host { connectionsByHost[host, default: 0] += count }
    }

    /// Return `count` connections to the budgets when a download ends (cleanly,
    /// by failure, or by pause/remove cancellation).
    func releaseConnections(host: String?, count: Int) {
        totalConnections = max(0, totalConnections - count)
        if let host {
            let remaining = (connectionsByHost[host] ?? 0) - count
            if remaining > 0 { connectionsByHost[host] = remaining }
            else { connectionsByHost[host] = nil }
        }
    }

    // MARK: Segment count

    /// The connection count this download may open, drawn from the cross-download
    /// budget. ``SegmentedTransfer`` applies the remaining (size-only) clamp.
    func resolveSegmentCount(total: Int64, host: String?) -> Int {
        // The Low profile opts out of extra connections entirely (its
        // `enableExtraConnections` flag): one connection, no segmentation.
        guard profile.enableExtraConnections else { return 1 }
        var want = max(1, profile.maxConnectionsPerServer)
        // Share the per-server budget with any other in-flight download to the
        // same host, and the global budget across every concurrent download, so
        // the profile's advertised caps hold in aggregate (floor of 1 so a new
        // download never stalls with zero connections).
        let hostInUse = host.flatMap { connectionsByHost[$0] } ?? 0
        want = min(want, max(1, profile.maxConnectionsPerServer - hostInUse))
        want = min(want, max(1, profile.maxConnections - totalConnections))
        let minSegment: Int64 = 64 * 1024
        let bySize = max(1, Int((total + minSegment - 1) / minSegment))
        return max(1, min(want, bySize))
    }
}
