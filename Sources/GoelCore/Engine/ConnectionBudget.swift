import Foundation

// MARK: - Cross-download connection budget

/// Cross-download connection accounting: enforces the profile's global `maxConnections` and per-host
/// caps in sum (``ConnectionGovernor`` is the per-download one). Value type owned by ``HTTPEngine``.
struct ConnectionBudget: Sendable, Equatable {
    var totalConnections = 0
    var connectionsByHost: [String: Int] = [:]

    // MARK: Reserve / release

    /// Charge `count` connections to the global and per-host budgets.
    mutating func reserve(host: String?, count: Int) {
        guard count > 0 else { return }
        totalConnections += count
        if let host { connectionsByHost[host, default: 0] += count }
    }

    /// Return `count` connections when a download ends (cleanly, by failure, or
    /// by pause/remove cancellation).
    mutating func release(host: String?, count: Int) {
        guard count > 0 else { return }
        totalConnections = max(0, totalConnections - count)
        if let host {
            let remaining = (connectionsByHost[host] ?? 0) - count
            if remaining > 0 { connectionsByHost[host] = remaining }
            else { connectionsByHost[host] = nil }
        }
    }

    // MARK: Room

    /// Connections already charged to `host` (0 when unknown / nil).
    func hostInUse(_ host: String?) -> Int {
        host.flatMap { connectionsByHost[$0] } ?? 0
    }

    /// Remaining per-host slots under `maxPerServer` (floor of 1 so a new download
    /// never stalls with zero connections).
    func hostRoom(host: String?, maxPerServer: Int) -> Int {
        max(1, maxPerServer - hostInUse(host))
    }

    /// Remaining global slots under `maxConnections` (floor of 1).
    func globalRoom(maxConnections: Int) -> Int {
        max(1, maxConnections - totalConnections)
    }

    /// Room for MID-FLIGHT extras: min of per-host and global free slots, floored at 0 — not 1, as the
    /// download already holds one (``HTTPEngine/grantExtraConnections(host:wanted:)``). Low grants none.
    func extraRoom(host: String?, profile: TrafficProfile) -> Int {
        guard profile.enableExtraConnections else { return 0 }
        let hostFree = profile.maxConnectionsPerServer - hostInUse(host)
        let globalFree = profile.maxConnections - totalConnections
        return max(0, min(hostFree, globalFree))
    }

    // MARK: Segment count

    /// Connection count this download may open, from profile + budget. ``SegmentedTransfer`` applies
    /// the remaining size-only clamp on resume / multi-path paths.
    func resolveSegmentCount(total: Int64, host: String?, profile: TrafficProfile) -> Int {
        // Low profile opts out of extra connections entirely.
        guard profile.enableExtraConnections else { return 1 }
        var want = max(1, profile.maxConnectionsPerServer)
        want = min(want, hostRoom(host: host, maxPerServer: profile.maxConnectionsPerServer))
        want = min(want, globalRoom(maxConnections: profile.maxConnections))
        let minSegment: Int64 = 64 * 1024
        // `(total - 1) / minSegment + 1`, not `(total + minSegment - 1) / …`: the latter overflows and
        // traps on a server-supplied declared size near `Int64.max`.
        let bySize = total <= 0 ? 1 : Int(min(Int64(Int.max), (total - 1) / minSegment + 1))
        return max(1, min(want, bySize))
    }
}
