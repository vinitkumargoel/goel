import Foundation

/// A `Sendable` snapshot of the user's proxy choice, so it can cross actor
/// boundaries (the raw CFNetwork `[String: Any]` dictionary is not Sendable).
///
/// A free-standing value type — promoted out of the `NetworkGuard` Port so the
/// shared engine configuration (`TorrentSessionConfig`, `HTTPEngine`) can name it
/// without depending on the Port's `URLSession`/CFNetwork machinery. `NetworkGuard`
/// still owns the `ProxySpec → connectionProxyDictionary` translation.
public struct ProxySpec: Sendable, Equatable {
    public var mode: String   // "system" | "manual" | "none"
    public var type: String   // "http" | "socks5"
    public var host: String
    public var port: Int
    public init(mode: String = "system", type: String = "http",
                host: String = "", port: Int = 0) {
        self.mode = mode; self.type = type; self.host = host; self.port = port
    }
}
