import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Identity is the interface **name** (`en0`), never a bare IP: egress scoping needs a name/index bind (`IP_BOUND_IF` / `SO_BINDTODEVICE`).
public struct NetworkAdapter: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName }

    public var bsdName: String

    public var displayName: String

    public var type: String

    public var ipv4: String?

    public var ipv6: String?

    public var isUp: Bool

    public var isExpensive: Bool

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
        displayName.isEmpty ? bsdName : "\(displayName) (\(bsdName))"
    }
}

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

    /// Both `manual` and `system` proxy disable it: the bound curl path ignores PAC/system proxy and would leak past it.
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
        if proxyMode == "manual" || proxyMode == "system" { return .proxy }
        if vpnDefaultRoute && !allowOutsideVPN { return .vpn }
        if usableAdapterCount < 2 { return .tooFewAdapters }
        return nil
    }

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
            // `includeVPN` is reserved for a future advanced mode; v1 always excludes tunnels from the fan-out.
            _ = includeVPN
            if a.type == "vpn" || isVPNInterfaceName(a.bsdName) { return false }
            if isHiddenVirtual(a.bsdName) { return false }
            if a.isExpensive && !includeExpensive { return false }
            if a.ipv4 == nil && a.ipv6 == nil { return false }
            return true
        }
    }

    public static func effectiveSelection(selectedIds: [String], all: [NetworkAdapter]) -> [String] {
        if !selectedIds.isEmpty { return selectedIds }
        return all.map(\.bsdName)
    }

    /// Excludes `utun`/`bridge`: hiding `utun` broke VPN detection and hiding `bridge` hid iPhone USB tethering.
    public static func isHiddenVirtual(_ bsdName: String) -> Bool {
        let n = bsdName.lowercased()
        if n == "lo" || (n.hasPrefix("lo") && n.count <= 4) { return true }
        let prefixes = ["awdl", "llw", "ap", "anpi", "gif", "stf", "p2p", "vmnet",
                        "veth", "docker", "br-", "virbr", "cni", "flannel", "cali", "kube",
                        "dummy"]
        return prefixes.contains { n.hasPrefix($0) }
    }

    public static func isVPNInterfaceName(_ bsdName: String) -> Bool {
        let n = bsdName.lowercased()
        return n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp")
            || n.hasPrefix("tun") || n.hasPrefix("tap") || n.hasPrefix("wg")
            // Linux names these plainly rather than tun*, so a prefix sweep misses them and offers the tunnel as an uplink.
            || n.hasPrefix("tailscale") || n.hasPrefix("zt") || n.hasPrefix("nebula")
            || n.hasPrefix("proton") || n.hasPrefix("nordlynx")
    }

    public static func preferredSegmentCount(
        adapters: Int,
        streamsPerAdapter: Int,
        maxAllowed: Int
    ) -> Int {
        let want = max(1, adapters) * max(1, streamsPerAdapter)
        let cap = max(1, maxAllowed)
        let floor = min(max(1, adapters), cap)
        return max(floor, min(want, cap))
    }

    public static func multiPathSegmentCount(
        fileBytes: Int64,
        adapters: Int,
        streamsPerAdapter: Int,
        maxConnectionsPerServer: Int,
        globalRoom: Int
    ) -> Int {
        let nAdapters = max(1, adapters)
        let streams = max(1, streamsPerAdapter)
        // Smaller floor than single-path so a ~1–2 MB file can still split across NICs.
        let minSeg: Int64 = 32 * 1024
        let bySize = max(1, Int((max(0, fileBytes) + minSeg - 1) / minSeg))
        let profileCap = max(1, maxConnectionsPerServer)
        let room = max(1, globalRoom)
        let hardCap = min(32, bySize, profileCap, room)
        let want = nAdapters * streams
        let floor = min(nAdapters, hardCap)
        return max(floor, min(want, hardCap))
    }
}

public enum AdapterDirectory {
    public static func enumerate() -> [NetworkAdapter] {
        rawEnumerate(includeVPNNames: false)
            .filter { $0.isUp && ($0.ipv4 != nil || $0.ipv6 != nil) }
            .filter { !AggregationPolicy.isVPNInterfaceName($0.bsdName) && $0.type != "vpn" }
            .sorted { $0.bsdName < $1.bsdName }
    }

    /// Deliberately not the multi-path virtual filter — `utun*` is exactly what VPN policy must see.
    public static func hasActiveVPNInterface() -> Bool {
        rawEnumerate(includeVPNNames: true).contains {
            $0.isUp && (AggregationPolicy.isVPNInterfaceName($0.bsdName) || $0.type == "vpn")
        }
    }

    private static func rawEnumerate(includeVPNNames: Bool) -> [NetworkAdapter] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            // On Linux this needs AF_NETLINK: a systemd `RestrictAddressFamilies=` without it silently reports no interfaces.
            GoelLog.app.error("Could not enumerate network interfaces",
                              .detail("getifaddrs failed (errno \(errno))"))
            return []
        }
        defer { freeifaddrs(first) }

        var map: [String: NetworkAdapter] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)

            let isVPN = AggregationPolicy.isVPNInterfaceName(name)
            if !includeVPNNames || !isVPN {
                if AggregationPolicy.isHiddenVirtual(name) { continue }
            }

            let flags = Int32(ifa.pointee.ifa_flags)
            let isUp = (flags & InterfaceFlag.up) != 0 && (flags & InterfaceFlag.running) != 0
            if (flags & InterfaceFlag.loopback) != 0 { continue }

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
                        if !ip.lowercased().hasPrefix("fe80") {
                            entry.ipv6 = entry.ipv6 ?? ip
                        }
                    }
                }
            }
            map[name] = entry
        }
        return Array(map.values)
    }

    public static func classify(_ bsdName: String) -> String {
        let n = bsdName.lowercased()
        if AggregationPolicy.isVPNInterfaceName(n) { return "vpn" }
        if n.hasPrefix("wlan") || n.hasPrefix("wl") { return "wifi" }
        if n.hasPrefix("eth") || n.hasPrefix("en") || n.hasPrefix("em") || n.hasPrefix("igb") {
            return "wired"
        }
        if n.hasPrefix("wwan") || n.hasPrefix("pdp") || n.hasPrefix("rmnet") { return "cellular" }
        // iPhone USB Personal Hotspot commonly appears as bridge100 / bridge*.
        if n.hasPrefix("bridge") { return "cellular" }
        return "other"
    }

    public static func looksExpensive(_ bsdName: String) -> Bool {
        let n = bsdName.lowercased()
        if n.hasPrefix("wwan") || n.hasPrefix("pdp") || n.hasPrefix("rmnet") { return true }
        if n.hasPrefix("bridge") { return true }
        if classify(bsdName) == "cellular" { return true }
        return false
    }

    public static func friendlyName(for bsdName: String) -> String {
        let n = bsdName.lowercased()
        switch classify(bsdName) {
        case "wifi": return "Wi‑Fi"
        case "wired":
            if n.hasPrefix("en") { return "Ethernet / Wi‑Fi" }
            return "Wired"
        case "cellular":
            if n.hasPrefix("bridge") { return "Hotspot / USB tether" }
            return "Cellular"
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
