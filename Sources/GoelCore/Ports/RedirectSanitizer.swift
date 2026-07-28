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
        let originalHost = originalURL?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        // Only https→http: the new scheme alone would also strip on a same-host http→http hop.
        let downgradedToHTTP = (originalURL?.scheme?.lowercased() == "https")
            && (request.url?.scheme?.lowercased() != "https")
        guard originalHost != newHost || downgradedToHTTP else { return sanitized }
        for name in (request.allHTTPHeaderFields ?? [:]).keys
        where !crossHostSafeHeaders.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
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
        completionHandler(Self.followed(request, originalURL: task.originalRequest?.url))
    }
}
