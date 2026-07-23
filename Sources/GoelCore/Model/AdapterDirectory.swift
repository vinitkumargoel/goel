import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Live host-interface enumeration via `getifaddrs`. Split out of `NetworkAdapter.swift`
// (which keeps only the pure `NetworkAdapter`/`BoundAdapter`/`AggregationPolicy` value
// types) because this is genuine platform code — Darwin/Glibc socket calls — that must
// stay in the engine layer rather than the platform-free contract layer.

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
