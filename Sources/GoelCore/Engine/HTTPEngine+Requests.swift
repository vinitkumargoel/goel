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
    nonisolated func makeRequest(_ url: URL, userAgent: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if url.scheme?.lowercased() == "https",
           let host = url.host, let auth = credentials.basicAuthorization(forHost: host) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        return req
    }
}
