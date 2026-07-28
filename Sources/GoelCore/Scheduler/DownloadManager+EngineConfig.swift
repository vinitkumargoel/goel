import Foundation

extension DownloadManager {

    public func applyLimits() async {
        let profile = settings.effectiveProfile
        await httpEngine.applyLimits(profile)
        await torrentEngine.applyLimits(profile)
        await hlsEngine.applyLimits(profile)
        await ftpEngine.applyLimits(profile)
        await sftpEngine.applyLimits(profile)
    }

    func applyEngineConfigs() async {
        await applyLimits()
        await (httpEngine as? HTTPConfigurable)?.configure(httpNetworkConfig())
        // The engine re-resolves the name from headers, so it needs the same choice `makeTask` used.
        await (httpEngine as? HTTPConfigurable)?
            .configureFileConflictPolicy(settings.existingFileReaction)
        await (torrentEngine as? TorrentControlling)?.configure(torrentSessionConfig())
        await (hlsEngine as? HLSConfigurable)?.configure(maxHeight: settings.hlsMaxHeight)
        await applyAggregationConfig()
    }

    public func reapplyEngineConfigsPublic() async {
        await applyEngineConfigs()
    }

    func applyAggregationConfig() async {
        let config = Self.makeAggregationConfig(settings: settings, vpnDefaultRoute: vpnDefaultRouteActive)
        await (httpEngine as? HTTPConfigurable)?.configureAggregation(config)
    }

    public func setVPNDefaultRouteActive(_ active: Bool) {
        vpnDefaultRouteActive = active
    }

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

    /// Must still honour proxy/VPN policy: a bind bypasses both, leaking outside the tunnel.
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

    /// Keeps all concurrent HTTP downloads within the profile's global `maxConnections` in aggregate.
    func reapplyHTTPBudget() async {
        var profile = settings.effectiveProfile
        let activeHTTP = tasks.filter { $0.source.kind == .http && $0.status.isActive }.count
        if profile.maxConnections > 0, activeHTTP > 0 {
            let perDownload = max(1, profile.maxConnections / activeHTTP)
            profile.maxConnectionsPerServer = min(profile.maxConnectionsPerServer, perDownload)
        }
        await httpEngine.applyLimits(profile)
    }
}
