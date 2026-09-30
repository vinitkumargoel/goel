import Foundation
import GoelCore

/// The SSRF screen for the browser extension. Unlike the remote `/api/add` path it lets private
/// LAN targets through: the user clicked the link in their own browser, and a NAS on the LAN is
/// exactly where many of those links point. What stays refused is what a hostile page could use
/// to reach something the user never could from the browser: link-local (cloud metadata), and
/// Goel°'s own portal — on loopback or on any of this Mac's own addresses.
enum BrowserCaptureScreen {

    enum Verdict: Equatable {
        case allowed
        case refused(String)
    }

    /// Returns this Mac's own interface addresses (loopback included), lowercased literals.
    typealias LocalAddresses = @Sendable () -> Set<String>

    /// AWS's IPv6 instance-metadata address sits in fc00::/7, which is otherwise private and allowed.
    private static let metadataLiterals: Set<String> = ["fd00:ec2::254", "169.254.169.254"]

    /// Spelling-only, for the native host process that can't resolve names or read settings.
    static func spellingVerdict(_ url: URL, portalPort: Int?,
                                localAddresses: Set<String> = []) -> Verdict {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .refused("no host") }
        return verdict(forAddress: host, url: url, portalPort: portalPort, localAddresses: localAddresses)
    }

    /// Screens the spelling and every address the name resolves to (`localtest.me` is loopback
    /// hidden behind DNS). Skipped for names when a SOCKS proxy resolves them remotely. A name that
    /// doesn't resolve here is let through: it reaches nothing, and the engine fails and retries it
    /// like any other dead link — refusing it only lost the capture.
    static func verdict(_ url: URL, portalPort: Int?, resolvedByProxy: Bool,
                        resolve: @escaping NetworkGuard.HostResolver = NetworkGuard.hostResolver,
                        localAddresses: @escaping LocalAddresses = { BrowserCaptureScreen.interfaceAddresses() })
        async -> Verdict {
        let own = portalPort == nil ? [] : await Task.detached { localAddresses() }.value
        let spelled = spellingVerdict(url, portalPort: portalPort, localAddresses: own)
        guard spelled == .allowed, let host = url.host?.lowercased(),
              NetworkGuard.addressClass(ofLiteral: host) == nil,
              host != "localhost", !resolvedByProxy else { return spelled }
        guard let addresses = await Task.detached(operation: { resolve(host) }).value else { return .allowed }
        for address in addresses {
            let result = verdict(forAddress: address.lowercased(), url: url, portalPort: portalPort,
                                 localAddresses: own)
            if result != .allowed { return result }
        }
        return .allowed
    }

    private static func verdict(forAddress host: String, url: URL, portalPort: Int?,
                                localAddresses: Set<String>) -> Verdict {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if metadataLiterals.contains(bare) { return .refused("metadata") }
        let loopbackName = bare == "localhost" || bare.hasSuffix(".localhost")
        switch classify(bare) {
        case .linkLocal?: return .refused("link-local")
        case .loopback?:
            return hitsPortal(url, portalPort) ? .refused("portal") : .allowed
        case nil where loopbackName || isOwnAddress(bare, localAddresses):
            return hitsPortal(url, portalPort) ? .refused("portal") : .allowed
        default:
            return .allowed
        }
    }

    private static func isOwnAddress(_ literal: String, _ own: Set<String>) -> Bool {
        guard !own.isEmpty else { return false }
        // Drop a zone index (`fe80::1%en0`) so the spelling matches what getifaddrs reports.
        let bare = literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal
        return own.contains(bare) || own.contains(literal)
    }

    private static func hitsPortal(_ url: URL, _ portalPort: Int?) -> Bool {
        // Unknown portal port (the native host can't read settings): the app re-screens on drain.
        guard let portalPort else { return false }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return port == portalPort
    }

    enum AddressClass { case loopback, linkLocal }

    /// nil for a public/private address or for a name (not a literal). The address is judged by
    /// what it means (``NetworkGuard/addressClass(ofLiteral:)``), so mapped, NAT64 and 6to4
    /// spellings of 169.254.x.x or 127.x.x.x are caught too.
    static func classify(_ literal: String) -> AddressClass? {
        switch NetworkGuard.addressClass(ofLiteral: literal) {
        case .loopback?, .unspecified?: return .loopback
        case .linkLocal?: return .linkLocal
        default: return nil
        }
    }

    /// Every address on this Mac's interfaces, loopback included. Blocking — call it off the main actor.
    static func interfaceAddresses() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }
        var out: Set<String> = []
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let current = node {
            defer { node = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let literal = String(cString: buffer).lowercased()
            out.insert(literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal)
        }
        return out
    }
}
