import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Network adapter model

/// One host network interface that may participate in multi-path downloads.
/// Identity is the BSD/Linux interface **name** (e.g. `en0`) — never a bare IP —
/// because egress scoping requires name/index bind (`IP_BOUND_IF` / `SO_BINDTODEVICE`).
public struct NetworkAdapter: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName }

    /// Kernel interface name used for bind-if (en0, eth0, …).
    public var bsdName: String

    /// Human label for UI (Wi‑Fi, Ethernet, iPhone USB, …).
    public var displayName: String

    /// `wifi` | `wired` | `cellular` | `vpn` | `other`
    public var type: String

    /// Primary IPv4 if any (display only — not used for bind).
    public var ipv4: String?

    /// Primary IPv6 if any (display only).
    public var ipv6: String?

    public var isUp: Bool

    /// Personal hotspot / cellular-class path. Independent of pause-on-expensive.
    public var isExpensive: Bool

    /// Low Data Mode / constrained path hint when known.
    public var isConstrained: Bool

    public init(
        bsdName: String,
        displayName: String,
        type: String,
        ipv4: String? = nil,
        ipv6: String? = nil,
        isUp: Bool = true,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.type = type
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.isUp = isUp
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public var shortLabel: String {
        if displayName.isEmpty { return bsdName }
        return "\(displayName) (\(bsdName))"
    }
}

/// A bind target handed to a segment — name + UI label only.
public struct BoundAdapter: Sendable, Hashable, Codable {
    public var bsdName: String
    public var displayName: String
    public var isExpensive: Bool

    public init(bsdName: String, displayName: String, isExpensive: Bool = false) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.isExpensive = isExpensive
    }

    public init(_ adapter: NetworkAdapter) {
        self.bsdName = adapter.bsdName
        self.displayName = adapter.displayName.isEmpty ? adapter.bsdName : adapter.displayName
        self.isExpensive = adapter.isExpensive
    }

    public var label: String {
        displayName.isEmpty ? bsdName : displayName
    }
}

// MARK: - Pure aggregation policy (testable)

/// Pure decisions: when multi-path activates, which adapters qualify, why single-path.
public enum AggregationPolicy: Sendable {

    public enum SinglePathReason: String, Sendable, Equatable {
        case disabled = "Aggregation disabled in Settings"
        case tooFewAdapters = "Fewer than 2 selected adapters are up"
        case lowProfile = "Traffic profile forbids extra connections"
        case proxy = "Proxy mode blocks multi-path"
        case vpn = "VPN policy blocks multi-path"
        case noRanges = "Server does not support multi-path ranges"
        case serverRejected = "Server rejected multi-path"
        case protocolUnsupported = "This protocol does not support aggregation yet"
        case expensiveBlocked = "Expensive adapters excluded"
    }

    /// Whether aggregation may run given settings + usable adapters + profile + proxy.
    public static func shouldActivate(
        enabled: Bool,
        usableAdapterCount: Int,
        enableExtraConnections: Bool,
        proxyMode: String,
        vpnDefaultRoute: Bool,
        allowOutsideVPN: Bool
    ) -> SinglePathReason? {
        if !enabled { return .disabled }
        if !enableExtraConnections { return .lowProfile }
        if proxyMode == "manual" { return .proxy }
        if vpnDefaultRoute && !allowOutsideVPN { return .vpn }
        if usableAdapterCount < 2 { return .tooFewAdapters }
        return nil
    }

    /// Filter discovered adapters against user selection and expensive/VPN flags.
    public static func usableAdapters(
        all: [NetworkAdapter],
        selectedIds: [String],
        includeExpensive: Bool,
        includeVPN: Bool
    ) -> [NetworkAdapter] {
        let selected = Set(selectedIds)
        return all.filter { a in
            guard a.isUp else { return false }
            guard selected.isEmpty || selected.contains(a.bsdName) else { return false }
            if a.type == "vpn" && !includeVPN { return false }
            // Virtual noise — never auto-include even if selected empty means "all".
            if isHiddenVirtual(a.bsdName) { return false }
            if a.isExpensive && !includeExpensive { return false }
            // Need at least one routable address signal when we have address info;
            // adapters without any address are usually unusable for WAN.
            if a.ipv4 == nil && a.ipv6 == nil { return false }
            return true
        }
    }

    /// When `selectedIds` is empty and aggregation is on, treat as "all eligible".
    public static func effectiveSelection(selectedIds: [String], all: [NetworkAdapter]) -> [String] {
        if !selectedIds.isEmpty { return selectedIds }
        return all.map(\.bsdName)
    }

    public static func isHiddenVirtual(_ bsdName: String) -> Bool {
        let n = bsdName.lowercased()
        if n == "lo" || n.hasPrefix("lo") && n.count <= 4 { return true }
        let prefixes = ["awdl", "llw", "ap", "anpi", "bridge", "gif", "stf", "p2p", "utun", "vmnet", "veth", "docker", "br-"]
        return prefixes.contains { n.hasPrefix($0) }
    }

    /// Desired segment floor so each adapter gets work: adapters × streamsPerAdapter.
    public static func preferredSegmentCount(
        adapters: Int,
        streamsPerAdapter: Int,
        budget: Int
    ) -> Int {
        let want = max(1, adapters) * max(1, streamsPerAdapter)
        return max(1, min(want, max(1, budget)))
    }
}

// MARK: - Enumeration (getifaddrs)

public enum AdapterDirectory {

    /// Snapshot of currently up, non-virtual interfaces with addresses.
    public static func enumerate() -> [NetworkAdapter] {
        var result: [NetworkAdapter] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(first) }

        // name → accumulated
        var map: [String: NetworkAdapter] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            if AggregationPolicy.isHiddenVirtual(name) { continue }

            let flags = Int32(ifa.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            // Skip pure loopback even if misnamed.
            if (flags & IFF_LOOPBACK) != 0 { continue }

            var entry = map[name] ?? NetworkAdapter(
                bsdName: name,
                displayName: friendlyName(for: name),
                type: classify(name),
                isUp: isUp,
                isExpensive: looksExpensive(name),
                isConstrained: false
            )
            entry.isUp = entry.isUp || isUp
            if entry.type == "other" { entry.type = classify(name) }
            if !entry.isExpensive { entry.isExpensive = looksExpensive(name) }

            if let addr = ifa.pointee.ifa_addr {
                let family = Int32(addr.pointee.sa_family)
                if family == AF_INET {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len_compat),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        if !ip.hasPrefix("169.254.") { entry.ipv4 = ip }
                    }
                } else if family == AF_INET6 {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len_compat),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        // Skip link-local fe80::
                        if !ip.lowercased().hasPrefix("fe80") {
                            entry.ipv6 = entry.ipv6 ?? ip
                        }
                    }
                }
            }
            map[name] = entry
        }

        result = map.values
            .filter { $0.isUp && ($0.ipv4 != nil || $0.ipv6 != nil) }
            .sorted { $0.bsdName < $1.bsdName }
        return result
    }

    public static func classify(_ bsdName: String) -> String {
        let n = bsdName.lowercased()
        if n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp") { return "vpn" }
        if n.hasPrefix("wlan") || n.hasPrefix("wi") || n == "en0" { return "wifi" } // en0 often Wi‑Fi on Apple
        if n.hasPrefix("eth") || n.hasPrefix("en") || n.hasPrefix("em") || n.hasPrefix("igb") { return "wired" }
        if n.hasPrefix("wwan") || n.hasPrefix("pdp") || n.hasPrefix("rmnet") { return "cellular" }
        if n.hasPrefix("bridge") && (n.contains("phone") || n.count > 6) { return "cellular" }
        return "other"
    }

    public static func looksExpensive(_ bsdName: String) -> Bool {
        let n = bsdName.lowercased()
        if n.hasPrefix("wwan") || n.hasPrefix("pdp") || n.hasPrefix("rmnet") { return true }
        // iPhone USB tethering often appears as bridge / en with limited heuristics —
        // user must still opt in; we mark cellular-class names expensive.
        return false
    }

    public static func friendlyName(for bsdName: String) -> String {
        let n = bsdName.lowercased()
        switch classify(bsdName) {
        case "wifi": return "Wi‑Fi"
        case "wired": return n.hasPrefix("en") ? "Ethernet" : "Wired"
        case "cellular": return "Cellular"
        case "vpn": return "VPN"
        default: return bsdName
        }
    }
}

// sockaddr.sa_len is Darwin-only; on Linux use known sizes.
private extension sockaddr {
    var sa_len_compat: UInt32 {
        #if canImport(Darwin)
        return UInt32(sa_len)
        #else
        switch Int32(sa_family) {
        case AF_INET: return UInt32(MemoryLayout<sockaddr_in>.size)
        case AF_INET6: return UInt32(MemoryLayout<sockaddr_in6>.size)
        default: return UInt32(MemoryLayout<sockaddr>.size)
        }
        #endif
    }
}
