import Foundation

/// Session delegate stripping hand-set credential headers on a cross-host redirect: Foundation doesn't
/// scope them to a protection space, so `Authorization`/`Cookie`/`Referer` would reach a third party.
public final class RedirectSanitizer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    public static let shared = RedirectSanitizer()

    /// Headers safe across a host change / scheme downgrade: they describe client and transport, not
    /// authorization. Allow-list, not deny-list, so an unknown header (`X-Api-Key`, …) is dropped.
    static let crossHostSafeHeaders: Set<String> = [
        "user-agent", "accept", "accept-encoding", "accept-language",
        "range", "if-range",
    ]

    /// Strip origin-scoped headers when a redirect leaves `originalURL`'s host or downgrades https→http.
    /// Shared with the per-task `ChunkStreamer`/auto-fetch delegates; takes a URL so it is unit-testable.
    static func sanitize(_ request: URLRequest, originalURL: URL?) -> URLRequest {
        var sanitized = request
        let originalHost = originalURL?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        // Only https→http counts: judging from the new scheme alone would also fire on a same-host
        // http→http hop and strip the `Cookie`/`Authorization` that origin still needs.
        let downgradedToHTTP = (originalURL?.scheme?.lowercased() == "https")
            && (request.url?.scheme?.lowercased() != "https")
        guard originalHost != newHost || downgradedToHTTP else { return sanitized }
        for name in (request.allHTTPHeaderFields ?? [:]).keys
        where !crossHostSafeHeaders.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
    }

    /// The request for a redirect hop, or nil to refuse: an unscreened `Location` could 302 the app into
    /// `127.0.0.1`/`169.254.169.254`. See ``NetworkGuard/isAllowedSubresource(_:of:)``. Nil ⇒ the 3xx stands.
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
