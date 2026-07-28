import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Network hygiene for unattended fetches (`.torrent` body, RSS poll): no proxy bypass leaking the real
/// egress IP, bounded redirects, no internal-metadata targets. They used to run on `URLSession.shared`.
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

    /// ``ProxySpec`` → `connectionProxyDictionary`: nil ⇒ OS proxy ("system"), `[:]` ⇒ direct ("none"),
    /// populated ⇒ manual/SOCKS. Single source of truth for the probe sweep and these auto-fetches.
    public static func proxyDictionary(_ spec: ProxySpec) -> [String: Any]? {
        #if os(Linux)
        // CFNetwork proxy keys don't exist in swift-corelibs-foundation; on Linux the HTTP engine
        // exports http(s)_proxy env vars URLSession reads ambiently, so nil (follow ambient) is right.
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

    /// Acceptable automatic fetch target: http/https whose host isn't link-local (169.254/16, fe80::/10 —
    /// cloud metadata, a classic SSRF pivot). Private LAN stays allowed for self-hosted RSS/torrent servers.
    public static func isAllowedAutoTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else { return false }
        return !isLinkLocal(host)
    }

    /// Target check for a *remote-initiated* add (portal `POST /api/add`): refuses loopback as well as
    /// link-local (not-exposed services), but allows ftp/ftps/sftp and private LAN — NAS adds are the point.
    public static func isAllowedRemoteAddTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "ftps", "sftp"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return !isLinkLocal(host) && !isLoopbackOrUnspecified(host)
    }

    /// ``isAllowedRemoteAddTarget(_:)`` plus screening every resolved address — spelling alone misses
    /// `localtest.me`. Unresolvable passes (SOCKS5 resolves remotely); DNS rebinding needs connect-time.
    public static func isAllowedRemoteAddTargetResolvingNames(_ url: URL) async -> Bool {
        guard isAllowedRemoteAddTarget(url), let host = url.host else { return false }
        // Nothing to resolve for a literal — it was already classified above.
        guard addressClass(ofLiteral: host) == nil else { return true }
        // getaddrinfo blocks, so it runs off the cooperative pool.
        let addresses = await Task.detached { NetworkGuard.resolvedLiterals(of: host) }.value
        guard let addresses else { return true }
        return !addresses.contains { (addressClass(ofLiteral: $0) ?? .other) != .other }
    }

    /// Acceptability of a server-chosen sub-resource (HLS segment/key URI, redirect hop): same-host children
    /// pass, ones leaving the host must not be loopback/link-local. Spelling only — runs per segment line.
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

    /// Classify `host` when it is an IP literal, else nil. Parsed and judged on the address it *means*,
    /// never text-matched: `::ffff:7f00:1` is 127.0.0.1 and `::ffff:a9fe:a9fe` is the metadata address.
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
        // `inet_aton`, not `inet_pton`: matches what an ordinary resolver uses, so legacy forms
        // (`2130706433`, `0177.0.0.1`, `0x7f.1` → 127.0.0.1) parse while real hostnames decline.
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
        // ::ffff:0:0/96 (IPv4-mapped) and ::/96 (IPv4-compatible) carry a v4 address in the low 32
        // bits, so judge them as that address rather than waving them through as "some IPv6 host".
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
        hints.ai_socktype = PlatformSocket.stream
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

    /// Fetch `url` automatically: configured proxy, bounded redirect chain, cross-host header
    /// stripping, link-local refused on every hop. Nil on failure, non-2xx, or a refused target.
    public static func fetch(url: URL, proxy: ProxySpec, userAgent: String,
                             timeout: TimeInterval = 30) async -> Data? {
        guard isAllowedAutoTarget(url) else { return nil }
        let dictionary = proxyDictionary(proxy)
        // One session per proxy policy, kept forever (``SessionPool``); the delegate keys hops by
        // task so sharing is safe. Per-call sessions crashed the Linux daemon on teardown.
        let session = SessionPool.session(key: "guard-fetch/" + SessionPool.proxyKey(dictionary)) {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = dictionary
            return URLSession(configuration: config,
                              delegate: GuardedFetchDelegate(), delegateQueue: nil)
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req) else { return nil }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }
}

/// Redirect delegate for ``NetworkGuard/fetch(url:proxy:userAgent:timeout:)``: bounds the hop count,
/// refuses link-local targets, and strips cross-host secrets via ``RedirectSanitizer``.
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
        // Both screens: `isAllowedAutoTarget` rules the aimed-at address, `RedirectSanitizer` rules a
        // hop leaving the original host — stopping a public feed redirecting us into our own loopback.
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
