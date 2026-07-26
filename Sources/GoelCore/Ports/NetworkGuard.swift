import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Network hygiene for the app's *automatic*, no-confirmation fetches — the
/// `.torrent`-file body fetch and the RSS feed poll. These run with no user in
/// the loop, so they must not (a) bypass the configured proxy and leak the real
/// egress IP, (b) follow an unbounded redirect chain, or (c) be steered to an
/// internal metadata endpoint. `HTTPEngine`'s real downloads already handle all of
/// this; these side-channels historically used `URLSession.shared`, which does not.
public enum NetworkGuard {

    /// A `Sendable` snapshot of the user's proxy choice, so it can cross actor
    /// boundaries (the raw CFNetwork `[String: Any]` dictionary is not Sendable).
    public struct ProxySpec: Sendable, Equatable {
        public var mode: String   // "system" | "manual" | "none"
        public var type: String   // "http" | "socks5"
        public var host: String
        public var port: Int
        public init(mode: String = "system", type: String = "http",
                    host: String = "", port: Int = 0) {
            self.mode = mode; self.type = type; self.host = host; self.port = port
        }
    }

    /// Translate a ``ProxySpec`` into a `connectionProxyDictionary`: nil ⇒ follow
    /// the OS proxy ("system"), `[:]` ⇒ force direct ("none"), populated ⇒ the
    /// configured manual/SOCKS proxy. The single source of truth for the HTTP
    /// engine's probe sweep and these auto-fetches.
    public static func proxyDictionary(_ spec: ProxySpec) -> [String: Any]? {
        #if os(Linux)
        // CFNetwork proxy keys don't exist in swift-corelibs-foundation; on Linux
        // the HTTP engine exports http(s)_proxy env vars that URLSession reads
        // ambiently, so nil (follow ambient) is correct.
        return nil
        #else
        switch spec.mode {
        case "manual" where !spec.host.isEmpty && spec.port > 0:
            if spec.type == "socks5" {
                return [
                    kCFNetworkProxiesSOCKSEnable as String: 1,
                    kCFNetworkProxiesSOCKSProxy as String: spec.host,
                    kCFNetworkProxiesSOCKSPort as String: spec.port,
                ]
            }
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: spec.host,
                kCFNetworkProxiesHTTPPort as String: spec.port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: spec.host,
                kCFNetworkProxiesHTTPSPort as String: spec.port,
            ]
        case "none":
            return [:]
        default:
            return nil
        }
        #endif
    }

    /// Whether `url` is acceptable as an automatic fetch target: an http/https URL
    /// whose host is not a link-local address (169.254/16, fe80::/10 — the
    /// cloud-metadata / autoconfiguration range and a classic SSRF pivot). Private
    /// LAN ranges are deliberately allowed so a self-hosted RSS/torrent server on
    /// the user's own network still works; only the unambiguous metadata range and
    /// non-web schemes are refused.
    public static func isAllowedAutoTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else { return false }
        return !isLinkLocal(host)
    }

    /// Whether `url` is acceptable as the target of a *remote-initiated* add — the
    /// web portal's `POST /api/add`, where the caller is not sitting at the machine.
    ///
    /// Stricter than ``isAllowedAutoTarget`` in one way and looser in another. It
    /// refuses loopback as well as link-local: a portal client asking this host to
    /// fetch from its own `127.0.0.1` is asking it to reach services that were
    /// deliberately not exposed. It accepts the transfer schemes the app actually
    /// downloads with (ftp/ftps/sftp as well as http/https) — refusing those would
    /// break legitimate adds rather than close a hole, and the same host rules
    /// apply to them. Private LAN ranges stay allowed, deliberately and for the
    /// same reason as in ``isAllowedAutoTarget``: "add the file on my NAS from my
    /// phone" is the feature, not the attack.
    public static func isAllowedRemoteAddTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "ftps", "sftp"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return !isLinkLocal(host) && !isLoopbackOrUnspecified(host)
    }

    /// ``isAllowedRemoteAddTarget(_:)`` extended to screen the *addresses* a name
    /// resolves to, not just the way it is spelled.
    ///
    /// The spelling check alone is trivially sidestepped, because nothing stops an
    /// attacker pointing a perfectly ordinary hostname at 127.0.0.1: both
    /// `localtest.me` and `metadata.google.internal` are public DNS names that
    /// resolve straight into the ranges this guard exists to refuse. So the name
    /// is resolved and *every* answer is screened — one internal address anywhere
    /// in the set refuses the whole target, since we cannot control which of them
    /// the connection will pick.
    ///
    /// A name that does not resolve is allowed through: with a SOCKS5 proxy
    /// configured the app never resolves locally at all (the proxy does), so
    /// treating an unresolvable name as hostile would refuse every legitimate add
    /// made through a proxy. Such a target either fails to connect or is dialed by
    /// the proxy, in which case "loopback" is the proxy's, not this machine's.
    ///
    /// Screening a name is still not screening a socket: a record whose TTL
    /// expires between here and the connection (DNS rebinding) resolves again
    /// inside `URLSession`. Closing that needs the check at connect time against
    /// the address actually dialed, which is a transport-layer change, not one
    /// this seam can make.
    public static func isAllowedRemoteAddTargetResolvingNames(_ url: URL) async -> Bool {
        guard isAllowedRemoteAddTarget(url), let host = url.host else { return false }
        // Nothing to resolve for a literal — it was already classified above.
        guard addressClass(ofLiteral: host) == nil else { return true }
        // getaddrinfo blocks, so it runs off the cooperative pool.
        let addresses = await Task.detached { NetworkGuard.resolvedLiterals(of: host) }.value
        guard let addresses else { return true }
        return !addresses.contains { (addressClass(ofLiteral: $0) ?? .other) != .other }
    }

    /// Whether `url` is acceptable as a *sub-resource* of something already
    /// fetched — an HLS segment / AES-key URI, or the target of a redirect hop.
    ///
    /// These are not user-typed addresses: the remote server decides them, so a
    /// playlist body or a `302 Location` is exactly as trustworthy as whoever
    /// served it. Left unscreened, any download URL becomes a fetch of this
    /// machine's own loopback services or the cloud-metadata range, with the app
    /// as the confused deputy.
    ///
    /// A child on the *same host* as its parent is allowed unconditionally: that
    /// host was already reached deliberately, so a genuinely local media server
    /// keeps working (and a relative URI can name nothing else). A child that
    /// *leaves* that host must additionally not name loopback or the link-local /
    /// metadata range — a remote document has no business steering us there. Names
    /// are screened by spelling only, with no resolution: this runs once per
    /// segment line of a playlist that may hold tens of thousands of them.
    public static func isAllowedSubresource(_ url: URL, of parent: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        if let parentHost = parent?.host, parentHost.caseInsensitiveCompare(host) == .orderedSame {
            return true
        }
        return !isLinkLocal(host) && !isLoopbackOrUnspecified(host)
    }

    /// Whether `host` names this machine itself — by name, or by any spelling of a
    /// loopback / unspecified address.
    static func isLoopbackOrUnspecified(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        switch addressClass(ofLiteral: h) {
        case .loopback, .unspecified: return true
        default: return false
        }
    }

    static func isLinkLocal(_ host: String) -> Bool {
        addressClass(ofLiteral: host) == .linkLocal
    }

    // MARK: Address literals

    /// What an address literal points at, as far as this guard cares.
    enum AddressClass: Equatable {
        case loopback      // 127.0.0.0/8, ::1
        case unspecified   // 0.0.0.0/8, :: — reaches every local address
        case linkLocal     // 169.254.0.0/16 (cloud metadata), fe80::/10
        case other         // anything else, including the private LAN ranges
    }

    /// Classify `host` when it is an IP address literal, or nil when it is a name.
    ///
    /// Every spelling is parsed and judged on the address it *means*, rather than
    /// pattern-matched on its text. Text matching is what made this guard
    /// bypassable: `::ffff:7f00:1` and `[0:0:0:0:0:ffff:7f00:1]` are both
    /// 127.0.0.1 and neither starts with `127.` or `::ffff:127.`, and
    /// `::ffff:a9fe:a9fe` is the cloud-metadata address without the digits
    /// `169.254.` appearing anywhere in it.
    static func addressClass(ofLiteral host: String) -> AddressClass? {
        var text = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // Drop an IPv6 zone index (`fe80::1%en0`); it names an interface, not an
        // address, and `inet_pton` rejects the whole string with it attached.
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
            return classify(v6)
        }
        var v4 = in_addr()
        // `inet_aton`, not `inet_pton`: it is the parser an ordinary resolver
        // reaches for, so it accepts the legacy forms — `2130706433`, `0177.0.0.1`,
        // `0x7f.1` — that all arrive at 127.0.0.1. It also declines a real
        // hostname, so `0x-mirror.example.com` is correctly read as a name.
        guard inet_aton(text, &v4) == 1 else { return nil }
        return classify(UInt32(bigEndian: v4.s_addr))
    }

    private static func classify(_ v4: UInt32) -> AddressClass {
        switch v4 >> 24 {
        case 127: return .loopback
        case 0:   return .unspecified
        default:  break
        }
        if v4 >> 16 == 0xa9fe { return .linkLocal }   // 169.254.0.0/16
        return .other
    }

    private static func classify(_ v6: in6_addr) -> AddressClass {
        let b = withUnsafeBytes(of: v6) { Array($0) }
        guard b.count == 16 else { return .other }
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }                  // ::
        if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return .loopback }  // ::1
        // ::ffff:0:0/96 (IPv4-mapped) and ::/96 (IPv4-compatible) both carry a v4
        // address in the low 32 bits, so they are judged as that address rather
        // than waved through as "some IPv6 host".
        if b[0..<10].allSatisfy({ $0 == 0 }),
           (b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0) {
            return classify(b[12...].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return .linkLocal }            // fe80::/10
        return .other
    }

    /// Every address `host` currently resolves to, in textual form, or nil when it
    /// could not be resolved. Blocking; call it off the cooperative pool.
    static func resolvedLiterals(of host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }
        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = list
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            // NI_NUMERICHOST: we want the address, never a reverse-DNS name — a
            // PTR record is attacker-supplied text and would defeat the check.
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let literal = String(cString: buffer)
                if !literal.isEmpty { out.append(literal) }
            }
            node = current.pointee.ai_next
        }
        // Resolved, but nothing legible came back: no evidence either way, and the
        // caller treats nil as "could not resolve".
        return out.isEmpty ? nil : out
    }

    /// Fetch `url` on an automatic path: through the configured proxy, with a
    /// bounded redirect chain, cross-host header stripping, and link-local targets
    /// refused (initial and every redirect hop). Returns nil on any failure, a
    /// non-2xx status, or a refused target.
    public static func fetch(url: URL, proxy: ProxySpec, userAgent: String,
                             timeout: TimeInterval = 30) async -> Data? {
        guard isAllowedAutoTarget(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = proxyDictionary(proxy)
        let delegate = GuardedFetchDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req) else { return nil }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }
}

/// Redirect delegate for ``NetworkGuard/fetch(url:proxy:userAgent:timeout:)``:
/// bounds the hop count, refuses link-local targets, and strips cross-host
/// secrets via ``RedirectSanitizer``.
final class GuardedFetchDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxHops: Int
    private let lock = NSLock()
    private var hops: [Int: Int] = [:]   // task.taskIdentifier → redirect count

    init(maxHops: Int = 8) { self.maxHops = maxHops }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let id = task.taskIdentifier
        lock.lock(); let n = (hops[id] ?? 0) + 1; hops[id] = n; lock.unlock()
        // Both screens, because they refuse different things: `isAllowedAutoTarget`
        // is the rule for the address this fetch was *aimed* at, and
        // ``RedirectSanitizer/followed(_:originalURL:)`` adds the rule for a hop
        // that leaves the original host — which is what stops a public feed
        // redirecting an unattended fetch into this machine's own loopback.
        guard n <= maxHops, let url = request.url, NetworkGuard.isAllowedAutoTarget(url),
              let next = RedirectSanitizer.followed(request, originalURL: task.originalRequest?.url)
        else {
            completionHandler(nil)   // too many hops, or a refused target
            return
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); hops[task.taskIdentifier] = nil; lock.unlock()
    }
}
