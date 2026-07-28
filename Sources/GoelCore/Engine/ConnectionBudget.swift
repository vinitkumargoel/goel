import Foundation

struct ConnectionBudget: Sendable, Equatable {
    var totalConnections = 0
    var connectionsByHost: [String: Int] = [:]

    mutating func reserve(host: String?, count: Int) {
        guard count > 0 else { return }
        totalConnections += count
        if let host { connectionsByHost[host, default: 0] += count }
    }

    mutating func release(host: String?, count: Int) {
        guard count > 0 else { return }
        totalConnections = max(0, totalConnections - count)
        if let host {
            let remaining = (connectionsByHost[host] ?? 0) - count
            if remaining > 0 { connectionsByHost[host] = remaining }
            else { connectionsByHost[host] = nil }
        }
    }

    func hostInUse(_ host: String?) -> Int {
        host.flatMap { connectionsByHost[$0] } ?? 0
    }

    /// Floored at 1: a new download granted zero connections would stall forever.
    func hostRoom(host: String?, maxPerServer: Int) -> Int {
        max(1, maxPerServer - hostInUse(host))
    }

    func globalRoom(maxConnections: Int) -> Int {
        max(1, maxConnections - totalConnections)
    }

    /// Floored at 0, not 1: these are extras on top of the connection the download already holds.
    func extraRoom(host: String?, profile: TrafficProfile) -> Int {
        guard profile.enableExtraConnections else { return 0 }
        let hostFree = profile.maxConnectionsPerServer - hostInUse(host)
        let globalFree = profile.maxConnections - totalConnections
        return max(0, min(hostFree, globalFree))
    }

    func resolveSegmentCount(total: Int64, host: String?, profile: TrafficProfile) -> Int {
        guard profile.enableExtraConnections else { return 1 }
        var want = max(1, profile.maxConnectionsPerServer)
        want = min(want, hostRoom(host: host, maxPerServer: profile.maxConnectionsPerServer))
        want = min(want, globalRoom(maxConnections: profile.maxConnections))
        let minSegment: Int64 = 64 * 1024
        // Not `(total + minSegment - 1) / …`: that overflows and traps on a server-declared size near Int64.max.
        let bySize = total <= 0 ? 1 : Int(min(Int64(Int.max), (total - 1) / minSegment + 1))
        return max(1, min(want, bySize))
    }
}
