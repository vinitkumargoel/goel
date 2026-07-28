import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unattended fetches must not bypass the proxy (leaks the real egress IP) or reach internal metadata.
public enum NetworkGuard {

    /// Sendable snapshot: the raw CFNetwork `[String: Any]` proxy dictionary cannot cross actor boundaries.
    public struct ProxySpec: Sendable, Equatable {
        public var mode: String
        public var type: String
        public var host: String
        public var port: Int
        public init(mode: String = "system", type: String = "http",
                    host: String = "", port: Int = 0) {
            self.mode = mode; self.type = type; self.host = host; self.port = port
        }
    }

    /// nil ⇒ OS proxy, `[:]` ⇒ direct, populated ⇒ manual/SOCKS. The three are not interchangeable.
    public static func proxyDictionary(_ spec: ProxySpec) -> [String: Any]? {
        #if os(Linux)
        // corelibs has no CFNetwork proxy keys; the engine exports http(s)_proxy env vars instead.
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

    /// Refuses link-local (169.254/16, fe80::/10) — cloud metadata is the classic SSRF pivot.
    public static func isAllowedAutoTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else { return false }
        return !isLinkLocal(host)
    }

    /// Remote-initiated adds (`POST /api/add`) must also refuse loopback — those services are not exposed.
    public static func isAllowedRemoteAddTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "ftps", "sftp"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return !isLinkLocal(host) && !isLoopbackOrUnspecified(host)
    }

    /// Screens every resolved address too — spelling alone misses `localtest.me`.
    public static func isAllowedRemoteAddTargetResolvingNames(_ url: URL) async -> Bool {
        guard isAllowedRemoteAddTarget(url), let host = url.host else { return false }
        // A literal needs no resolution — it was already classified above, not waved through.
        guard addressClass(ofLiteral: host) == nil else { return true }
        // getaddrinfo blocks, so it must run off the cooperative pool.
        let addresses = await Task.detached { NetworkGuard.resolvedLiterals(of: host) }.value
        guard let addresses else { return true }
        return !addresses.contains { (addressClass(ofLiteral: $0) ?? .other) != .other }
    }

    /// Server-chosen sub-resources (HLS segment/key URI, redirect hop) may not leave the host for loopback/link-local.
    public static func isAllowedSubresource(_ url: URL, of parent: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        if let parentHost = parent?.host, parentHost.caseInsensitiveCompare(host) == .orderedSame {
            return true
        }
        return !isLinkLocal(host) && !isLoopbackOrUnspecified(host)
    }

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

    enum AddressClass: Equatable {
        case loopback
        case unspecified
        case linkLocal
        case other
    }

    /// Judge the address a literal *means*, never its text: `::ffff:7f00:1` is 127.0.0.1.
    static func addressClass(ofLiteral host: String) -> AddressClass? {
        var text = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // Drop an IPv6 zone index (`fe80::1%en0`) — `inet_pton` rejects the whole string with it attached.
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
            return classify(v6)
        }
        var v4 = in_addr()
        // `inet_aton`, not `inet_pton`: legacy forms (`2130706433`, `0177.0.0.1`) also reach 127.0.0.1.
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
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return .loopback }
        // IPv4-mapped/compatible (::ffff:0:0/96, ::/96) must be judged as their v4 address, not waved through.
        if b[0..<10].allSatisfy({ $0 == 0 }),
           (b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0) {
            return classify(b[12...].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return .linkLocal }            // fe80::/10
        return .other
    }

    /// Blocking — call it off the cooperative pool.
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
            // NI_NUMERICHOST is mandatory: a reverse-DNS PTR record is attacker-supplied text.
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let literal = String(cString: buffer)
                if !literal.isEmpty { out.append(literal) }
            }
            node = current.pointee.ai_next
        }
        return out.isEmpty ? nil : out
    }

    /// Configured proxy, bounded redirects, cross-host header stripping, link-local refused on every hop.
    public static func fetch(url: URL, proxy: ProxySpec, userAgent: String,
                             timeout: TimeInterval = 30) async -> Data? {
        guard isAllowedAutoTarget(url) else { return nil }
        let dictionary = proxyDictionary(proxy)
        // Pooled per proxy policy: per-call sessions crashed the Linux daemon on teardown.
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

/// Bounds the hop count, refuses link-local targets, strips cross-host secrets via ``RedirectSanitizer``.
final class GuardedFetchDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxHops: Int
    private let lock = NSLock()
    private var hops: [Int: Int] = [:]

    init(maxHops: Int = 8) { self.maxHops = maxHops }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let id = task.taskIdentifier
        lock.lock(); let n = (hops[id] ?? 0) + 1; hops[id] = n; lock.unlock()
        // Both screens are needed: a public feed must not redirect us into our own loopback.
        guard n <= maxHops, let url = request.url, NetworkGuard.isAllowedAutoTarget(url),
              let next = RedirectSanitizer.followed(request, originalURL: task.originalRequest?.url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); hops[task.taskIdentifier] = nil; lock.unlock()
    }
}
