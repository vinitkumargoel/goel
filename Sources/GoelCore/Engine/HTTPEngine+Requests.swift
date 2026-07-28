import Foundation

extension HTTPEngine {

    /// Basic `Authorization` is HTTPS-only: over plain `http://` it leaks the password.
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

    /// Never hand-roll from `task.requestHeaders` — ``DownloadTask/outboundHeaders(for:)`` scopes cookies host-exact.
    nonisolated func makeRequest(_ url: URL, userAgent: String,
                                 task: DownloadTask) -> URLRequest {
        makeRequest(url, userAgent: userAgent,
                    referer: task.referer,
                    extraHeaders: task.outboundHeaders(for: url))
    }
}
