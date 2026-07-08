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
    ///
    /// Proxy: both `manual` **and** `system` disable multi-path — the bound curl
    /// path does not honour PAC/system proxy, so allowing multi-path would bypass it.
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
            // VPN tunnels never join multi-path fan-out (physical bind only).
            // `includeVPN` is reserved for a future advanced mode; v1 always excludes.
            _ = includeVPN
            if a.type == "vpn" || isVPNInterfaceName(a.bsdName) { return false }
            // Virtual noise — never multi-path candidates.
            if isHiddenVirtual(a.bsdName) { return false }
            if a.isExpensive && !includeExpensive { return false }
            if a.ipv4 == nil && a.ipv6 == nil { return false }
            return true
        }
    }

    /// When `selectedIds` is empty and aggregation is on, treat as "all eligible".
    public static func effectiveSelection(selectedIds: [String], all: [NetworkAdapter]) -> [String] {
        if !selectedIds.isEmpty { return selectedIds }
        return all.map(\.bsdName)
    }

    /// Interfaces that must never appear as multi-path download adapters.
    /// **Does not include `utun`/`bridge`** — those are handled as VPN / tether
    /// classification, not blanket-hidden (hiding `utun` broke VPN detection;
    /// hiding `bridge` hid iPhone USB tethering).
    public static func isHiddenVirtual(_ bsdName: String) -> Bool {
        let n = bsdName.lowercased()
        if n == "lo" || (n.hasPrefix("lo") && n.count <= 4) { return true }
        let prefixes = ["awdl", "llw", "ap", "anpi", "gif", "stf", "p2p", "vmnet", "veth", "docker", "br-"]
        return prefixes.contains { n.hasPrefix($0) }
    }

    /// Tunnel / VPN interface names (used for policy detection, not multi-path bind).
    public static func isVPNInterfaceName(_ bsdName: String) -> Bool {
        let n = bsdName.lowercased()
        return n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp")
            || n.hasPrefix("tun") || n.hasPrefix("tap") || n.hasPrefix("wg")
    }

    /// Desired segment count: `adapters × streamsPerAdapter`, clamped to `maxAllowed`.
    public static func preferredSegmentCount(
        adapters: Int,
        streamsPerAdapter: Int,
        maxAllowed: Int
    ) -> Int {
        let want = max(1, adapters) * max(1, streamsPerAdapter)
        let cap = max(1, maxAllowed)
        // At least one segment per adapter when the budget allows.
        let floor = min(max(1, adapters), cap)
        return max(floor, min(want, cap))
    }

    /// How many segments a multi-path download should open.
    ///
    /// Unlike the single-path planner (64 KiB floor + host budget only), this
    /// **guarantees at least one segment per adapter** when the file is large
    /// enough, so traffic is not pinned to a single NIC.
    ///
    /// - Parameters:
    ///   - fileBytes: total size (must be known + ranged).
    ///   - adapters: usable bind targets (≥ 2 when multi-path is active).
    ///   - streamsPerAdapter: user setting (1…8).
    ///   - maxConnectionsPerServer: traffic-profile cap.
    ///   - globalRoom: remaining global connection slots.
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
        let hardCap = min(32, bySize, profileCap, room) // never absurd fan-out
        let want = nAdapters * streams
        // Floor: one segment per adapter whenever size allows ≥ adapters chunks.
        let floor = min(nAdapters, hardCap)
        return max(floor, min(want, hardCap))
    }
}

// MARK: - Enumeration (getifaddrs)

public enum AdapterDirectory {

    /// Snapshot of currently up interfaces suitable for multi-path UI / binding.
    /// Excludes loopback noise and pure virtual radios; **includes** bridge
    /// (USB tether) and classifies VPN names but leaves them out of usable set.
    public static func enumerate() -> [NetworkAdapter] {
        rawEnumerate(includeVPNNames: false)
            .filter { $0.isUp && ($0.ipv4 != nil || $0.ipv6 != nil) }
            .filter { !AggregationPolicy.isVPNInterfaceName($0.bsdName) && $0.type != "vpn" }
            .sorted { $0.bsdName < $1.bsdName }
    }

    /// True when any VPN/tunnel interface is up. **Does not** use the multi-path
    /// virtual filter — `utun*` is exactly what we must see for VPN policy.
    public static func hasActiveVPNInterface() -> Bool {
        rawEnumerate(includeVPNNames: true).contains {
            $0.isUp && (AggregationPolicy.isVPNInterfaceName($0.bsdName) || $0.type == "vpn")
        }
    }

    /// Full scan. When `includeVPNNames` is false, VPN ifaces are still classified
    /// but the multi-path list drops them later; when true they stay in the map
    /// for VPN detection even without routable addresses.
    private static func rawEnumerate(includeVPNNames: Bool) -> [NetworkAdapter] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
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
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
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
        // en0 is often Wi‑Fi on Apple laptops, but not always — leave as wired-class
        // hardware and let the display name say "Ethernet/Wi‑Fi" generically.
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
        // USB / Personal Hotspot tethering — treat as expensive so the independent
        // aggregation expensive gate applies (default off).
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
