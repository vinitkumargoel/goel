import Foundation

// MARK: - Request building

/// Request construction for the engine's own traffic; retry/backoff and classifiers moved with the
/// byte pumps to ``SegmentedTransfer/makeRequest(_:userAgent:)``. Kept for ``HTTPEngine/probe(_:)``.
extension HTTPEngine {

    /// `User-Agent` on every outbound request (none may be UA-less), plus preemptive Basic `Authorization`
    /// when credentials are stored — HTTPS only, since Basic over plain `http://` leaks the password.
    nonisolated func makeRequest(_ url: URL, userAgent: String,
                                 referer: String? = nil,
                                 extraHeaders: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: name)
        }
        if url.scheme?.lowercased() == "https",
           let host = url.host, let auth = credentials.basicAuthorization(forHost: host) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let referer, !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return req
    }

    /// Task-aware form: adds `Referer` and in-scope cookies — paywalled file vs. login page. Never hand-roll
    /// from `task.requestHeaders`; use ``DownloadTask/outboundHeaders(for:)`` (host-exact scope). Not logged.
    nonisolated func makeRequest(_ url: URL, userAgent: String,
                                 task: DownloadTask) -> URLRequest {
        makeRequest(url, userAgent: userAgent,
                    referer: task.referer,
                    extraHeaders: task.outboundHeaders(for: url))
    }
}
