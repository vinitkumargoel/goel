import Foundation

/// Session delegate stripping manually-attached credential/context headers when a
/// redirect crosses to a different host — Foundation doesn't scope a hand-set
/// header to a protection space, so without this a redirect could carry the
/// user's Basic credentials, `Referer`, `Cookie`, or any custom auth header to an
/// arbitrary third party.
///
/// This is a network/redirect-safety concern; it lives beside ``NetworkGuard``
/// (whose `GuardedFetchDelegate` forwards to it) rather than in the credential
/// store, so anyone hunting redirect-hardening logic finds it in the Ports seam.
public final class RedirectSanitizer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    public static let shared = RedirectSanitizer()

    /// Headers safe to carry across a host change / scheme downgrade because they
    /// describe the client and transport, not the user's authorization to one
    /// origin. Everything else on the original request — `Authorization`,
    /// `Cookie`, `Referer`, AND any custom per-task header the user attached for
    /// the original host (e.g. `X-Api-Key`, `PRIVATE-TOKEN`, `X-Auth-Token`) — is a
    /// secret scoped to that host and must be dropped, not just the three we can
    /// name. Allow-list (not a deny-list) so a header we've never heard of is
    /// treated as sensitive by default.
    static let crossHostSafeHeaders: Set<String> = [
        "user-agent", "accept", "accept-encoding", "accept-language",
        "range", "if-range",
    ]

    /// Strip every origin-scoped header from `request` when a redirect crosses to
    /// a different host (relative to `originalURL`) or downgrades https→http. Shared
    /// by this session-level delegate and the per-task `ChunkStreamer`/auto-fetch
    /// delegates (which supersede it for their task). Takes the original URL rather
    /// than the task so it is directly unit-testable.
    static func sanitize(_ request: URLRequest, originalURL: URL?) -> URLRequest {
        var sanitized = request
        let originalHost = originalURL?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        let downgradedToHTTP = (request.url?.scheme?.lowercased() != "https")
        guard originalHost != newHost || downgradedToHTTP else { return sanitized }
        for name in (request.allHTTPHeaderFields ?? [:]).keys
        where !crossHostSafeHeaders.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.sanitize(request, originalURL: task.originalRequest?.url))
    }
}
