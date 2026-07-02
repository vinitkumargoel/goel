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
        await sftpEngine.applyLimits(profile)
    }

    /// Push limits *and* the network/session configuration derived from the
    /// current settings to the engines. `applyLimits` is the bandwidth/connection
    /// hot path (kept separate); each engine then configures through its OWN typed
    /// seam, reached by an intentional capability query (`as? HTTPConfigurable`
    /// etc.). An engine that doesn't implement a config slice simply doesn't
    /// conform to its refinement — no shared union, no per-engine no-ops, no
    /// concrete-type downcast.
    func applyEngineConfigs() async {
        await applyLimits()
        await (httpEngine as? HTTPConfigurable)?.configure(httpNetworkConfig())
        await (torrentEngine as? TorrentControlling)?.configure(torrentSessionConfig())
        await (hlsEngine as? HLSConfigurable)?.configure(maxHeight: settings.hlsMaxHeight)
    }

    private func httpNetworkConfig() -> HTTPNetworkConfig {
        HTTPNetworkConfig(
            timeout: settings.connectionTimeout,
            retryCount: settings.retryCount,
            retryInterval: settings.retryInterval,
            userAgent: settings.userAgent,
            proxyMode: settings.proxyMode,
            proxyType: settings.proxyType,
            proxyHost: settings.proxyHost,
            proxyPort: settings.proxyPort,
            cookieAuthEnabled: settings.cookieAuthEnabled
        )
    }

    private func torrentSessionConfig() -> TorrentSessionConfig {
        TorrentSessionConfig(
            encryptionMode: settings.btEncryptionMode,
            enableDHT: settings.btEnableDHT,
            enablePeX: settings.btEnablePeX,
            enableLPD: settings.btEnableLPD,
            enableUTP: settings.btEnableUTP
        )
    }

    /// Re-apply the HTTP engine's per-server connection cap so the *aggregate* of
    /// all concurrently running HTTP downloads stays within the profile's global
    /// `maxConnections`, instead of every download independently claiming the full
    /// per-server fan-out. Best-effort: already-running segment groups keep their
    /// governor; the tighter cap takes effect for subsequently computed segments.
    func reapplyHTTPBudget() async {
        var profile = settings.effectiveProfile
        let activeHTTP = tasks.filter { $0.source.kind == .http && $0.status.isActive }.count
        if profile.maxConnections > 0, activeHTTP > 0 {
            let perDownload = max(1, profile.maxConnections / activeHTTP)
            profile.maxConnectionsPerServer = min(profile.maxConnectionsPerServer, perDownload)
        }
        // `applyLimits` is universal (base protocol), so the per-host budget is
        // re-applied to the HTTP engine with no concrete-type downcast.
        await httpEngine.applyLimits(profile)
    }
}
