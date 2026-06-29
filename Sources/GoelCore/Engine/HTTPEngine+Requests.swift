import Foundation

// MARK: - Request building & retry policy

/// Request construction and the retry/backoff policy. Split out of ``HTTPEngine``
/// so the transfer paths read without the request plumbing inline. `makeRequest`
/// and `backoff` are `nonisolated` (no actor state), the classifiers are `static`.
extension HTTPEngine {

    /// Builds a request carrying the client `User-Agent`. `nonisolated` so the
    /// nonisolated segment/streaming paths can use it too. All outbound
    /// requests must go through here so none are sent UA-less.
    nonisolated func makeRequest(_ url: URL, userAgent: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// HTTP statuses worth retrying: explicit rate-limiting plus transient
    /// upstream/server errors.
    static func isRetryableStatus(_ status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    /// Network-level errors that a retry can plausibly recover from (a dropped
    /// connection, a timeout, a refused/transient host). Deliberately excludes
    /// `.cancelled` (our own pause/remove) and non-network errors (disk, etc.).
    static func isTransient(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Sleeps before the next attempt: honours a numeric `Retry-After` header
    /// when present, otherwise exponential backoff. Jitter de-synchronises a
    /// burst of segments that were all rate-limited at once (thundering herd).
    /// `Task.sleep` throws on cancellation, so pause/remove still interrupt.
    nonisolated func backoff(attempt: Int, response: HTTPURLResponse?, retryInterval: Double) async throws {
        var seconds = min(6.0, pow(2.0, Double(attempt - 1)) * 0.4)
        // A configured retry interval acts as a floor on the wait (0 = leave the
        // built-in exponential backoff untouched).
        if retryInterval > 0 { seconds = max(seconds, retryInterval) }
        if let header = response?.value(forHTTPHeaderField: "Retry-After"),
           let advised = Double(header.trimmingCharacters(in: .whitespaces)) {
            seconds = min(15.0, max(seconds, advised))
        }
        seconds += Double.random(in: 0...0.4)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
