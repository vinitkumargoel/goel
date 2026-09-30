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

    /// SOCKS5 hands the hostname to the proxy, so nothing this machine resolves describes the real target.
    public static func usesRemoteDNS(_ spec: ProxySpec) -> Bool {
        spec.mode == "manual" && spec.type == "socks5" && !spec.host.isEmpty && spec.port > 0
    }

    public typealias HostResolver = @Sendable (String) -> [String]?

    /// Seam so a screen can be exercised without a live resolver deciding the verdict for it.
    public static var hostResolver: HostResolver {
        get { resolverBox.get() }
        set { resolverBox.set(newValue) }
    }

    /// A stub left behind by one test would silently unscreen every later one, so restoring is explicit.
    public static func useSystemHostResolver() {
        resolverBox.set(systemHostResolver)
    }

    private static let systemHostResolver: HostResolver = { resolvedLiterals(of: $0) }
    private static let resolverBox = LockedBox<HostResolver>(systemHostResolver)

    /// Reached from actors and from `@MainActor`; the lock is what makes the shared seams safe there.
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
    }

    /// Refuses link-local (169.254/16, fe80::/10) — cloud metadata is the classic SSRF pivot.
    public static func isAllowedAutoTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else { return false }
        return !isLinkLocal(host)
    }

    /// Remote-initiated adds (`POST /api/add`, portal, browser extension) must also refuse loopback and
    /// private ranges: a token holder must not read the router admin page back through `/stream`.
    /// A user typing a LAN URL into the GUI never reaches this screen.
    public static func isAllowedRemoteAddTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "ftps", "sftp"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        guard !isLinkLocal(host), !isLoopbackOrUnspecified(host) else { return false }
        if addressClass(ofLiteral: host) == .privateNetwork { return isAllowlistedPrivate(host) }
        return true
    }

    /// Operator escape hatch for remote adds from a known LAN host (a NAS): exact host names,
    /// IPv4 literals or IPv4 CIDRs. Never unlocks loopback or link-local, only private ranges.
    public static var privateTargetAllowlist: [String] {
        get { allowlistBox.get() }
        set { allowlistBox.set(newValue) }
    }
    private static let allowlistBox = LockedBox<[String]>([])

    static func isAllowlistedPrivate(_ host: String) -> Bool {
        let patterns = privateTargetAllowlist
        guard !patterns.isEmpty else { return false }
        let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if patterns.contains(where: { $0.lowercased() == bare }) { return true }
        return IPMatcher.matches(bare, any: patterns)
    }

    /// Screens every resolved address too — spelling alone misses `localtest.me`. Fails closed on an unresolvable name.
    /// Callers pass `resolvedByProxy` from their own proxy state rather than have this read settings,
    /// so which screen ran stays visible at the call site instead of depending on hidden config.
    public static func isAllowedRemoteAddTargetResolvingNames(
        _ url: URL, resolvedByProxy: Bool = false) async -> Bool {
        guard isAllowedRemoteAddTarget(url), let host = url.host else { return false }
        // A literal needs no resolution — it was already classified above, not waved through.
        guard addressClass(ofLiteral: host) == nil else { return true }
        // Skipped deliberately: under SOCKS5 the proxy is the trust boundary and the resolver, so a local
        // answer screens a different host — and refusing would refuse every intranet name and .onion.
        guard !resolvedByProxy else { return true }
        // getaddrinfo blocks, so it must run off the cooperative pool.
        let resolve = hostResolver
        let addresses = await Task.detached { resolve(host) }.value
        // No addresses means the screen could not run, not that the name is safe: a lookup that fails
        // here can still answer 127.0.0.1 for the real fetch, so refuse instead of waving it through.
        guard let addresses else {
            GoelLog.remote.error("Refusing a target whose name could not be resolved for screening",
                                 .host(host))
            return false
        }
        // An allowlisted NAS name may resolve private; it still may not resolve to loopback.
        let allowPrivate = isAllowlistedPrivate(host)
        return !addresses.contains { address in
            switch addressClass(ofLiteral: address) ?? .other {
            case .other: return false
            case .privateNetwork: return !(allowPrivate || isAllowlistedPrivate(address))
            default: return true
            }
        }
    }

    public struct ScreenResult: Sendable, Equatable {
        public var allowed: [DownloadSource]
        public var refused: [DownloadSource]
    }

    /// The one SSRF loop for untrusted adds (remote API, extension spool): magnets pass, every
    /// fetchable target is judged by its resolved addresses.
    public static func screen(sources: [DownloadSource],
                              resolvedByProxy: Bool = false) async -> ScreenResult {
        var result = ScreenResult(allowed: [], refused: [])
        for source in sources {
            guard let url = source.fetchTargetURL else { result.allowed.append(source); continue }
            if await isAllowedRemoteAddTargetResolvingNames(url, resolvedByProxy: resolvedByProxy) {
                result.allowed.append(source)
            } else {
                GoelLog.remote.error("Refusing an internal-network target",
                                     .state(url.scheme ?? "", label: "scheme"))
                result.refused.append(source)
            }
        }
        return result
    }

    /// Server-chosen sub-resources (HLS segment/key URI, redirect hop) may not leave the host for
    /// loopback/link-local, nor hop from a public parent into a private range. Spelling only — the
    /// redirect delegates follow up with ``isAllowedRedirectResolvingNames(_:from:)``.
    public static func isAllowedSubresource(_ url: URL, of parent: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        if let parentHost = parent?.host, parentHost.caseInsensitiveCompare(host) == .orderedSame {
            return true
        }
        guard !isLinkLocal(host), !isLoopbackOrUnspecified(host) else { return false }
        if addressClass(ofLiteral: host) == .privateNetwork {
            return parentLooksLocal(parent) || isAllowlistedPrivate(host)
        }
        return true
    }

    /// Without resolving, a parent counts as local only by spelling: a private/loopback literal or a
    /// LAN-style name (`nas`, `nas.local`, `router.lan`). A public-looking name is treated as public.
    static func parentLooksLocal(_ parent: URL?) -> Bool {
        guard let host = parent?.host?.lowercased(), !host.isEmpty else { return false }
        switch addressClass(ofLiteral: host) {
        case .privateNetwork?, .loopback?: return true
        case .some: return false
        case nil: break
        }
        if !host.contains(".") { return true }
        return [".local", ".lan", ".home", ".internal", ".localdomain", ".home.arpa", ".localhost"]
            .contains { host.hasSuffix($0) }
    }

    /// The redirect-hop screen that also sees through DNS: `127.0.0.1.nip.io` spells nothing
    /// internal. Unresolvable hops pass (a proxy may be the only resolver); the fetch then fails
    /// or reaches what the proxy resolves — positive evidence of an internal address is required.
    public static func isAllowedRedirectResolvingNames(_ url: URL, from parent: URL?) async -> Bool {
        guard isAllowedSubresource(url, of: parent), let host = url.host else { return false }
        if let parentHost = parent?.host, parentHost.caseInsensitiveCompare(host) == .orderedSame {
            return true
        }
        guard addressClass(ofLiteral: host) == nil else { return true }   // literal: judged above
        let resolve = hostResolver
        guard let addresses = await Task.detached(operation: { resolve(host) }).value else {
            return true
        }
        let classes = addresses.map { addressClass(ofLiteral: $0) ?? .other }
        if classes.contains(where: { $0 == .loopback || $0 == .unspecified || $0 == .linkLocal }) {
            return false
        }
        guard classes.contains(.privateNetwork), !isAllowlistedPrivate(host) else { return true }
        return await parentIsLocalResolving(parent)
    }

    private static func parentIsLocalResolving(_ parent: URL?) async -> Bool {
        if parentLooksLocal(parent) { return true }
        guard let host = parent?.host, addressClass(ofLiteral: host) == nil else { return false }
        let resolve = hostResolver
        guard let addresses = await Task.detached(operation: { resolve(host) }).value else {
            return false
        }
        return addresses.contains {
            let c = addressClass(ofLiteral: $0)
            return c == .privateNetwork || c == .loopback
        }
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

    public enum AddressClass: Equatable, Sendable {
        case loopback
        case unspecified
        case linkLocal
        /// RFC1918, CGNAT, benchmarking, IETF protocol assignments, ULA.
        case privateNetwork
        case other
    }

    /// Judge the address a literal *means*, never its text: `::ffff:7f00:1` is 127.0.0.1.
    public static func addressClass(ofLiteral host: String) -> AddressClass? {
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
        let privateRanges: [(network: UInt32, bits: UInt32)] = [
            (0x0A00_0000, 8),    // 10.0.0.0/8
            (0xAC10_0000, 12),   // 172.16.0.0/12
            (0xC0A8_0000, 16),   // 192.168.0.0/16
            (0x6440_0000, 10),   // 100.64.0.0/10  CGNAT (also Tailscale)
            (0xC000_0000, 24),   // 192.0.0.0/24   IETF protocol assignments
            (0xC612_0000, 15),   // 198.18.0.0/15  benchmarking
        ]
        for range in privateRanges where v4 >> (32 - range.bits) == range.network >> (32 - range.bits) {
            return .privateNetwork
        }
        return .other
    }

    private static func classify(_ v6: in6_addr) -> AddressClass {
        let b = withUnsafeBytes(of: v6) { Array($0) }
        guard b.count == 16 else { return .other }
        func v4(at i: Int) -> UInt32 { b[i..<(i + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return .loopback }
        // IPv4-mapped/compatible (::ffff:0:0/96, ::/96) must be judged as their v4 address, not waved through.
        if b[0..<10].allSatisfy({ $0 == 0 }),
           (b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0) {
            return classify(v4(at: 12))
        }
        // NAT64 (64:ff9b::/96) and 6to4 (2002::/16) carry a v4 address a gateway will reach for us.
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
            return classify(v4(at: 12))
        }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4] == 0x00, b[5] == 0x01 {
            return .privateNetwork                                            // 64:ff9b:1::/48 local-use
        }
        if b[0] == 0x20, b[1] == 0x02 { return classify(v4(at: 2)) }
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return .linkLocal }            // fe80::/10
        if b[0] & 0xfe == 0xfc { return .privateNetwork }                     // fc00::/7 ULA
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

    /// Why a guarded fetch produced no body — surfaced so "Could not fetch the .torrent" can say 404 vs TLS.
    public enum FetchError: Error, Sendable, Equatable, CustomStringConvertible {
        case refusedTarget
        case httpStatus(Int)
        case transport(String)

        public var description: String {
            switch self {
            case .refusedTarget:
                return L10n.t("That address is on this machine or a link-local range — refused.")
            case .httpStatus(let code) where (300..<400).contains(code):
                // A refused hop surfaces as the 3xx itself: the delegate declined to follow it.
                return L10n.t("Server redirected (HTTP %ld) to an address that was not followed", code)
            case .httpStatus(let code):
                return L10n.t("Server returned HTTP %ld (%@)", code,
                              HTTPURLResponse.localizedString(forStatusCode: code))
            case .transport(let reason):
                return reason
            }
        }
    }

    /// Nil-on-failure convenience over ``fetchChecked(url:proxy:userAgent:timeout:)``.
    public static func fetch(url: URL, proxy: ProxySpec, userAgent: String,
                             timeout: TimeInterval = 30) async -> Data? {
        try? await fetchChecked(url: url, proxy: proxy, userAgent: userAgent, timeout: timeout)
    }

    /// Configured proxy, bounded redirects, cross-host header stripping, link-local refused on every hop.
    /// Throws ``FetchError`` carrying the HTTP status or the transport error's text.
    public static func fetchChecked(url: URL, proxy: ProxySpec, userAgent: String,
                                    timeout: TimeInterval = 30) async throws -> Data {
        guard isAllowedAutoTarget(url) else { throw FetchError.refusedTarget }
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
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.httpStatus(http.statusCode)
        }
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
        let original = task.originalRequest?.url
        guard n <= maxHops, let url = request.url, NetworkGuard.isAllowedAutoTarget(url),
              let next = RedirectSanitizer.followed(request, originalURL: original)
        else {
            completionHandler(nil)
            return
        }
        RedirectSanitizer.resolveThenFollow(next, url: url, originalURL: original,
                                            completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); hops[task.taskIdentifier] = nil; lock.unlock()
    }
}
