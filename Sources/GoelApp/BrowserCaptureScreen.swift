import Foundation
import GoelCore

/// The SSRF screen for the browser extension. Unlike the remote `/api/add` path it lets private
/// LAN targets through: the user clicked the link in their own browser, and a NAS on the LAN is
/// exactly where many of those links point. What stays refused is what a hostile page could use
/// to reach something the user never could from the browser: link-local (cloud metadata), and
/// Goel°'s own portal on loopback.
enum BrowserCaptureScreen {

    enum Verdict: Equatable {
        case allowed
        case refused(String)
    }

    /// AWS's IPv6 instance-metadata address sits in fc00::/7, which is otherwise private and allowed.
    private static let metadataLiterals: Set<String> = ["fd00:ec2::254", "169.254.169.254"]

    /// Spelling-only, for the native host process that can't resolve names or read settings.
    static func spellingVerdict(_ url: URL, portalPort: Int?) -> Verdict {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .refused("no host") }
        return verdict(forAddress: host, url: url, portalPort: portalPort)
    }

    /// Screens the spelling and every address the name resolves to (`localtest.me` is loopback
    /// hidden behind DNS). Skipped for names when a SOCKS proxy resolves them remotely.
    static func verdict(_ url: URL, portalPort: Int?, resolvedByProxy: Bool,
                        resolve: @escaping NetworkGuard.HostResolver = NetworkGuard.hostResolver) async -> Verdict {
        let spelled = spellingVerdict(url, portalPort: portalPort)
        guard spelled == .allowed, let host = url.host?.lowercased(),
              classify(host) == nil, host != "localhost", !resolvedByProxy else { return spelled }
        let addresses = await Task.detached { resolve(host) }.value
        guard let addresses else { return .refused("unresolvable") }
        for address in addresses {
            let result = verdict(forAddress: address.lowercased(), url: url, portalPort: portalPort)
            if result != .allowed { return result }
        }
        return .allowed
    }

    private static func verdict(forAddress host: String, url: URL, portalPort: Int?) -> Verdict {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if metadataLiterals.contains(bare) { return .refused("metadata") }
        let loopbackName = bare == "localhost" || bare.hasSuffix(".localhost")
        switch classify(bare) {
        case .linkLocal?: return .refused("link-local")
        case .loopback?:
            return hitsPortal(url, portalPort) ? .refused("portal") : .allowed
        case nil where loopbackName:
            return hitsPortal(url, portalPort) ? .refused("portal") : .allowed
        default:
            return .allowed
        }
    }

    private static func hitsPortal(_ url: URL, _ portalPort: Int?) -> Bool {
        // Unknown portal port (the native host can't read settings): the app re-screens on drain.
        guard let portalPort else { return false }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return port == portalPort
    }

    enum AddressClass { case loopback, linkLocal }

    /// nil for a public/private address or for a name (not a literal).
    static func classify(_ literal: String) -> AddressClass? {
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            return classify(v4: UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &v6) == 1 else { return nil }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0..<15].allSatisfy({ $0 == 0 }) && (b[15] == 1 || b[15] == 0) { return .loopback }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return .linkLocal }
        // ::ffff:a.b.c.d carries an IPv4 address that must be judged as one.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            let embedded = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
            return classify(v4: embedded)
        }
        return nil
    }

    private static func classify(v4 address: UInt32) -> AddressClass? {
        switch address >> 24 {
        case 127, 0: return .loopback
        case 169 where (address >> 16) & 0xff == 254: return .linkLocal
        default: return nil
        }
    }
}
