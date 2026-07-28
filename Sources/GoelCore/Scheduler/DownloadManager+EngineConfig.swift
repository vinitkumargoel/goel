import Foundation

// MARK: - Engine configuration

/// Pushes settings down to the concrete engines — `DownloadEngine.applyLimits` plus network/session
/// config. Split out of ``DownloadManager`` so the scheduler proper stays focused on the queue.
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

    /// Push limits *and* network/session config. `applyLimits` stays separate as the hot path; each engine
    /// configures via its own typed seam (`as? HTTPConfigurable`) — no union, no concrete-type downcast.
    func applyEngineConfigs() async {
        await applyLimits()
        await (httpEngine as? HTTPConfigurable)?.configure(httpNetworkConfig())
        // The engine re-resolves a download's name once response headers arrive, so
        // it needs the same "when a file exists" choice `makeTask` applied.
        await (httpEngine as? HTTPConfigurable)?
            .configureFileConflictPolicy(settings.existingFileReaction)
        await (torrentEngine as? TorrentControlling)?.configure(torrentSessionConfig())
        await (hlsEngine as? HLSConfigurable)?.configure(maxHeight: settings.hlsMaxHeight)
        await applyAggregationConfig()
    }

    /// Public re-entry for the app layer after adapter/settings changes.
    public func reapplyEngineConfigsPublic() async {
        await applyEngineConfigs()
    }

    /// Build multi-path config from settings + live interfaces and push to HTTPEngine.
    func applyAggregationConfig() async {
        let config = Self.makeAggregationConfig(settings: settings, vpnDefaultRoute: vpnDefaultRouteActive)
        await (httpEngine as? HTTPConfigurable)?.configureAggregation(config)
    }

    /// Whether the system default route appears to be a VPN interface (utun/…).
    /// Updated by the app layer via ``setVPNDefaultRouteActive``.
    public func setVPNDefaultRouteActive(_ active: Bool) {
        vpnDefaultRouteActive = active
    }

    /// Pure builder for the aggregation engine snapshot (unit-testable).
    static func makeAggregationConfig(
        settings: AppSettings,
        vpnDefaultRoute: Bool,
        adapters: [NetworkAdapter]? = nil
    ) -> AggregationEngineConfig {
        let all = adapters ?? AdapterDirectory.enumerate()
        let selected = AggregationPolicy.effectiveSelection(
            selectedIds: settings.aggregationAdapterIds, all: all)
        let usable = AggregationPolicy.usableAdapters(
            all: all,
            selectedIds: selected,
            includeExpensive: settings.aggregationIncludeExpensive,
            includeVPN: settings.aggregationAllowOutsideVPN
        )
        let available = bindableAdapters(
            settings: settings, vpnDefaultRoute: vpnDefaultRoute, all: all)
        if AggregationPolicy.shouldActivate(
            enabled: settings.aggregationEnabled,
            usableAdapterCount: usable.count,
            enableExtraConnections: settings.effectiveProfile.enableExtraConnections,
            proxyMode: settings.proxyMode,
            vpnDefaultRoute: vpnDefaultRoute,
            allowOutsideVPN: settings.aggregationAllowOutsideVPN
        ) != nil {
            // No default fan-out, but a task may still pin itself to one interface.
            return AggregationEngineConfig(
                adapters: [],
                available: available.map(BoundAdapter.init),
                streamsPerAdapter: settings.aggregationStreamsPerAdapter)
        }
        return AggregationEngineConfig(
            adapters: usable.map(BoundAdapter.init),
            available: available.map(BoundAdapter.init),
            streamsPerAdapter: settings.aggregationStreamsPerAdapter
        )
    }

    /// Interfaces a *single task* may bind to. Ignores the aggregation toggle, saved selection and
    /// expensive filter (defaults being overridden) but **not** proxy/VPN policy — a bind bypasses both.
    public static func bindableAdapters(
        settings: AppSettings,
        vpnDefaultRoute: Bool,
        all: [NetworkAdapter]? = nil
    ) -> [NetworkAdapter] {
        if settings.proxyMode == "manual" || settings.proxyMode == "system" { return [] }
        if vpnDefaultRoute && !settings.aggregationAllowOutsideVPN { return [] }
        return AggregationPolicy.usableAdapters(
            all: all ?? AdapterDirectory.enumerate(),
            selectedIds: [],
            includeExpensive: true,
            includeVPN: false)
    }

    /// User-visible reason multi-path is inactive (nil when active).
    public static func aggregationSinglePathReason(
        settings: AppSettings,
        vpnDefaultRoute: Bool,
        adapters: [NetworkAdapter]? = nil
    ) -> AggregationPolicy.SinglePathReason? {
        let all = adapters ?? AdapterDirectory.enumerate()
        let selected = AggregationPolicy.effectiveSelection(
            selectedIds: settings.aggregationAdapterIds, all: all)
        let usable = AggregationPolicy.usableAdapters(
            all: all,
            selectedIds: selected,
            includeExpensive: settings.aggregationIncludeExpensive,
            includeVPN: settings.aggregationAllowOutsideVPN
        )
        return AggregationPolicy.shouldActivate(
            enabled: settings.aggregationEnabled,
            usableAdapterCount: usable.count,
            enableExtraConnections: settings.effectiveProfile.enableExtraConnections,
            proxyMode: settings.proxyMode,
            vpnDefaultRoute: vpnDefaultRoute,
            allowOutsideVPN: settings.aggregationAllowOutsideVPN
        )
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
            enableUTP: settings.btEnableUTP,
            proxy: Self.proxySpec(from: settings)
        )
    }

    /// Re-apply the per-server cap so all concurrent HTTP downloads *in aggregate* stay within the
    /// profile's global `maxConnections`. Best-effort: running segment groups keep their governor.
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
