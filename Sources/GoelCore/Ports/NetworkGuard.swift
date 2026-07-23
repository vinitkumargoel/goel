import Foundation

/// Network hygiene for the app's *automatic*, no-confirmation fetches — the
/// `.torrent`-file body fetch and the RSS feed poll. These run with no user in
/// the loop, so they must not (a) bypass the configured proxy and leak the real
/// egress IP, (b) follow an unbounded redirect chain, or (c) be steered to an
/// internal metadata endpoint. `HTTPEngine`'s real downloads already handle all of
/// this; these side-channels historically used `URLSession.shared`, which does not.
public enum NetworkGuard {

    // ``ProxySpec`` moved to `Model/ProxySpec.swift` (a top-level value type) so the
    // shared engine config can name it without depending on this Port. `NetworkGuard`
    // still owns the translation below.

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

    static func isLinkLocal(_ host: String) -> Bool {
        if host.hasPrefix("169.254.") { return true }   // IPv4 link-local / metadata
        // IPv6 link-local fe80::/10 spans fe80–febf; hosts may arrive bracketed.
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
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
        guard n <= maxHops, let url = request.url, NetworkGuard.isAllowedAutoTarget(url) else {
            completionHandler(nil)   // too many hops, or a refused/link-local target
            return
        }
        completionHandler(RedirectSanitizer.sanitize(request, originalURL: task.originalRequest?.url))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); hops[task.taskIdentifier] = nil; lock.unlock()
    }
}
