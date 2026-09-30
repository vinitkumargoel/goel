import Foundation

/// Foundation doesn't scope hand-set headers to a protection space: `Authorization`/`Cookie` would reach a third party.
public final class RedirectSanitizer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    public static let shared = RedirectSanitizer()

    /// Allow-list, never a deny-list: an unknown header (`X-Api-Key`, …) must be dropped.
    static let crossHostSafeHeaders: Set<String> = [
        "user-agent", "accept", "accept-encoding", "accept-language",
        "range", "if-range",
    ]

    static func sanitize(_ request: URLRequest, originalURL: URL?) -> URLRequest {
        var sanitized = request
        guard !keepsSecrets(from: originalURL, to: request.url) else { return sanitized }
        for name in (request.allHTTPHeaderFields ?? [:]).keys
        where !crossHostSafeHeaders.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
    }

    /// Mirrors `gcb_redirect_keeps_secrets`: same scheme+host+port, or the http→https upgrade on
    /// default ports. A port change is another server (`:8080` may be anyone's), so it strips.
    static func keepsSecrets(from origin: URL?, to hop: URL?) -> Bool {
        guard let a = origin, let b = hop,
              let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased(),
              let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased(),
              hostA == hostB else { return false }
        let portA = a.port ?? defaultPort(schemeA)
        let portB = b.port ?? defaultPort(schemeB)
        if schemeA == schemeB { return portA == portB }
        return schemeA == "http" && schemeB == "https" && portA == 80 && portB == 443
    }

    private static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// Nil refuses the hop: an unscreened `Location` can 302 the app into `127.0.0.1`/`169.254.169.254`.
    static func followed(_ request: URLRequest, originalURL: URL?) -> URLRequest? {
        guard let next = request.url,
              NetworkGuard.isAllowedSubresource(next, of: originalURL) else { return nil }
        return sanitize(request, originalURL: originalURL)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        guard let next = Self.followed(request, originalURL: original), let url = next.url else {
            completionHandler(nil)
            return
        }
        Self.resolveThenFollow(next, url: url, originalURL: original,
                               completionHandler: completionHandler)
    }

    /// The spelling screen already passed; this one resolves the hop's name (`127.0.0.1.nip.io`).
    /// getaddrinfo blocks, so the verdict arrives on a detached task — URLSession waits for it.
    static func resolveThenFollow(_ next: URLRequest, url: URL, originalURL: URL?,
                                  completionHandler: @escaping (URLRequest?) -> Void) {
        let reply = UncheckedHandler(completionHandler)
        Task.detached {
            let allowed = await NetworkGuard.isAllowedRedirectResolvingNames(url, from: originalURL)
            if !allowed {
                GoelLog.remote.error("Refusing a redirect hop that resolves to an internal address",
                                     .state(url.scheme ?? "", label: "scheme"))
            }
            reply.call(allowed ? next : nil)
        }
    }

    /// URLSession's completion handler predates Sendable; it is documented callable from any thread.
    private struct UncheckedHandler: @unchecked Sendable {
        let body: (URLRequest?) -> Void
        init(_ body: @escaping (URLRequest?) -> Void) { self.body = body }
        func call(_ request: URLRequest?) { body(request) }
    }
}
