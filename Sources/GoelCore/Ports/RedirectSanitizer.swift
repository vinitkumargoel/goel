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
        // A downgrade is a *loss* of transport security, so it has to be judged
        // against where we started: only https→http qualifies. Deciding from the
        // new scheme alone would also fire on a same-host http→http hop, which
        // exposes nothing new (the first request already went out in the clear)
        // yet would strip the `Cookie`/`Authorization` the origin still needs —
        // turning a plain-http intranet redirect into a silent auth failure.
        let downgradedToHTTP = (originalURL?.scheme?.lowercased() == "https")
            && (request.url?.scheme?.lowercased() != "https")
        guard originalHost != newHost || downgradedToHTTP else { return sanitized }
        for name in (request.allHTTPHeaderFields ?? [:]).keys
        where !crossHostSafeHeaders.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
    }

    /// The request to send for a redirect hop, or nil to refuse the hop.
    ///
    /// Stripping headers was only half the job: the handler used to follow every
    /// `Location` it was handed, so a URL the user (or the portal, or the browser
    /// extension) added could 302 the app into `127.0.0.1` or `169.254.169.254`
    /// and none of the screening done on the *original* address applied to where
    /// it actually ended up. A hop is now judged exactly as any other
    /// server-chosen sub-resource is — see ``NetworkGuard/isAllowedSubresource(_:of:)``
    /// for why leaving the original host is the line that matters.
    ///
    /// Refusing returns nil, which makes the 3xx itself the task's response. Every
    /// engine here checks the status code, so the download fails rather than
    /// silently saving a redirect body.
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
