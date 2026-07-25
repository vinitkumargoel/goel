import Foundation

// MARK: - Request building

/// Request construction for the engine's own traffic (the probe). The transfer
/// path builds its requests through ``SegmentedTransfer/makeRequest(_:userAgent:)``;
/// the retry/backoff policy and status classifiers moved there with the byte
/// pumps. `makeRequest` stays here because ``HTTPEngine/probe(_:)`` still uses it.
extension HTTPEngine {

    /// Builds a request carrying the client `User-Agent` — and, when the user
    /// has stored credentials for the host, a preemptive Basic `Authorization`
    /// header. Credentials only ever ride over TLS: attaching Basic auth to a
    /// plain `http://` request would broadcast the password in cleartext.
    /// `nonisolated` so callers off the actor can use it too. All outbound
    /// requests must go through here so none are sent UA-less.
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

    /// The task-aware form: the same request, plus the task's `Referer` and its
    /// captured browser cookies when they are in scope for `url`.
    ///
    /// Cookies are the difference between downloading a paywalled/logged-in file
    /// and downloading the site's login page, so this overload exists to make the
    /// correct call site the easy one: it resolves headers through
    /// ``DownloadTask/outboundHeaders(for:)``, which applies the host-exact scope
    /// check. Building a request from `task.requestHeaders` by hand skips that
    /// check and must not be done.
    ///
    /// The cookie value is never logged here or anywhere else — see the storage
    /// note on ``DownloadTask/cookieHeader``.
    nonisolated func makeRequest(_ url: URL, userAgent: String,
                                 task: DownloadTask) -> URLRequest {
        makeRequest(url, userAgent: userAgent,
                    referer: task.referer,
                    extraHeaders: task.outboundHeaders(for: url))
    }
}
