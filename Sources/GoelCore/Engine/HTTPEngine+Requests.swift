import Foundation

// MARK: - Request building

/// Request construction for the engine's own traffic (the probe). The transfer
/// path builds its requests through ``SegmentedTransfer/makeRequest(_:userAgent:)``;
/// the retry/backoff policy and status classifiers moved there with the byte
/// pumps. `makeRequest` stays here because ``HTTPEngine/probe(_:)`` still uses it.
extension HTTPEngine {

    /// Builds a request carrying the client `User-Agent`. `nonisolated` so callers
    /// off the actor can use it too. All outbound requests must go through here so
    /// none are sent UA-less.
    nonisolated func makeRequest(_ url: URL, userAgent: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }
}
