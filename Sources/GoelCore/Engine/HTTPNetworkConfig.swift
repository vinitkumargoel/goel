import Foundation

// MARK: - Network configuration

/// Network settings pushed into the engine from preferences: timeout, proxy, User-Agent, cookies,
/// retry budget. The bandwidth cap lives on `TrafficProfile`; engine defaults hold until `applyNetworkConfig`.
public struct HTTPNetworkConfig: Sendable, Equatable {
    public var timeout: Double
    public var retryCount: Int
    public var retryInterval: Double
    public var userAgent: String
    public var proxyMode: String   // none | system | manual
    public var proxyType: String   // http | socks5 (only used when proxyMode == manual)
    public var proxyHost: String
    public var proxyPort: Int
    public var cookieAuthEnabled: Bool

    public init(
        timeout: Double = 30,
        retryCount: Int = 3,
        retryInterval: Double = 5,
        userAgent: String = "GoelDownloader/1.0 (macOS)",
        proxyMode: String = "none",
        proxyType: String = "http",
        proxyHost: String = "",
        proxyPort: Int = 0,
        cookieAuthEnabled: Bool = true
    ) {
        self.timeout = timeout
        self.retryCount = retryCount
        self.retryInterval = retryInterval
        self.userAgent = userAgent
        self.proxyMode = proxyMode
        self.proxyType = proxyType
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.cookieAuthEnabled = cookieAuthEnabled
    }
}

// MARK: - Network aggregation (multi-path)

/// Snapshot of multi-adapter download policy pushed into ``HTTPEngine``.
/// Built by ``DownloadManager`` from ``AppSettings`` + live adapter enumeration.
public struct AggregationEngineConfig: Sendable, Equatable {
    /// What the server-wide policy binds by default. Empty = follow the routing table.
    public var adapters: [BoundAdapter]
    /// Every bindable interface, including ones the default policy declined. A task
    /// can pin to one of these even with aggregation globally off.
    public var available: [BoundAdapter]
    public var streamsPerAdapter: Int

    public init(
        adapters: [BoundAdapter] = [],
        available: [BoundAdapter] = [],
        streamsPerAdapter: Int = 2
    ) {
        self.adapters = adapters
        self.available = available
        self.streamsPerAdapter = max(1, streamsPerAdapter)
    }

    public static let disabled = AggregationEngineConfig(
        adapters: [], available: [], streamsPerAdapter: 2)

    public var isActive: Bool { adapters.count >= 2 }
}


