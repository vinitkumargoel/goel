import Foundation

// MARK: - Engine configuration

/// Pushes the user's settings down to the concrete engines — bandwidth/connection
/// limits (the `DownloadEngine` protocol's `applyLimits`) plus the production
/// engines' network/session config. Split out of ``DownloadManager`` so the
/// scheduler proper stays focused on the queue.
extension DownloadManager {

    /// Push the current effective profile's bandwidth/connection caps to both
    /// engines. Useful at startup and whenever the profile or snail changes.
    public func applyLimits() async {
        let profile = settings.effectiveProfile
        await httpEngine.applyLimits(profile)
        await torrentEngine.applyLimits(profile)
        await hlsEngine.applyLimits(profile)
        await ftpEngine.applyLimits(profile)
    }

    /// Push limits *and* the network/session configuration derived from the
    /// current settings to every engine. `applyLimits` is the bandwidth/connection
    /// hot path (kept separate); `configure(_:)` is the unified `DownloadEngine`
    /// seam — the manager builds one ``EngineConfiguration`` and hands the same
    /// value to each engine, which picks out only the slice it understands. No
    /// engine is downcast to a concrete type.
    func applyEngineConfigs() async {
        await applyLimits()
        let configuration = engineConfiguration()
        for engine in [httpEngine, torrentEngine, hlsEngine, ftpEngine] {
            await engine.configure(configuration)
        }
    }

    /// Assemble the engine-agnostic configuration from the current settings.
    private func engineConfiguration() -> EngineConfiguration {
        EngineConfiguration(
            http: httpNetworkConfig(),
            torrent: torrentSessionConfig(),
            hlsMaxHeight: settings.hlsMaxHeight
        )
    }

    private func httpNetworkConfig() -> HTTPNetworkConfig {
        HTTPNetworkConfig(
            timeout: settings.connectionTimeout,
            retryCount: settings.retryCount,
            retryInterval: settings.retryInterval,
            userAgent: settings.userAgent,
            proxyMode: settings.proxyMode,
            proxyHost: settings.proxyHost,
            proxyPort: settings.proxyPort,
            cookieAuthEnabled: settings.cookieAuthEnabled
        )
    }

    private func torrentSessionConfig() -> TorrentEngine.SessionConfig {
        TorrentEngine.SessionConfig(
            enableDHT: settings.btEnableDHT,
            enableLSD: settings.btEnableLPD,
            enableUTP: settings.btEnableUTP,
            encryptionMode: settings.btEncryptionMode
        )
    }

    /// Re-apply the HTTP engine's per-server connection cap so the *aggregate* of
    /// all concurrently running HTTP downloads stays within the profile's global
    /// `maxConnections`, instead of every download independently claiming the full
    /// per-server fan-out. Best-effort: already-running segment groups keep their
    /// governor; the tighter cap takes effect for subsequently computed segments.
    func reapplyHTTPBudget() async {
        guard let http = httpEngine as? HTTPEngine else { return }
        var profile = settings.effectiveProfile
        let activeHTTP = tasks.filter { $0.source.kind == .http && $0.status.isActive }.count
        if profile.maxConnections > 0, activeHTTP > 0 {
            let perDownload = max(1, profile.maxConnections / activeHTTP)
            profile.maxConnectionsPerServer = min(profile.maxConnectionsPerServer, perDownload)
        }
        await http.applyLimits(profile)
    }
}
