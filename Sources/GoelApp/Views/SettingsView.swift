import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

struct SettingsView: View {
    @EnvironmentObject private var vm: AppViewModel

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case network = "Network"
        case aggregation = "Aggregation"
        case traffic = "Traffic Limits"
        case bittorrent = "BitTorrent"
        case scheduler = "Scheduler"
        case rss = "RSS Feeds"
        case advanced = "Advanced"
        case antivirus = "Antivirus"
        case browser = "Browser"
        case remote = "Web Access"
        case audit = "Audit Log"
        case license = "Licence"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .network: return "globe"
            case .aggregation: return "point.3.connected.trianglepath.dotted"
            case .traffic: return "speedometer"
            case .bittorrent: return "circle.grid.cross"
            case .scheduler: return "clock"
            case .rss: return "dot.radiowaves.up.forward"
            case .advanced: return "wand.and.stars"
            case .antivirus: return "shield"
            case .browser: return "safari"
            case .remote: return "display"
            case .audit: return "doc.text.magnifyingglass"
            case .license: return "checkmark.seal"
            }
        }

        var comingSoon: Bool { false }

    }

    @State private var selection: Pane = .general

    @ObservedObject private var route = SettingsRoute.shared

    var body: some View {
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $selection) { pane in
                Label {
                    HStack {
                        Text(L10n.t(pane.rawValue))
                        if pane.comingSoon {
                            Spacer()
                            Text(L10n.t("soon"))
                                .scaledFont(size: 9)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                                .foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: pane.symbol)
                }
                .tag(pane)
                .opacity(pane.comingSoon ? 0.6 : 1)
            }
            .listStyle(.sidebar)
            .frame(width: 184)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    paneContent
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Clear the request once consumed, or asking for the same pane twice never fires onChange again.
        .onChange(of: route.requestedPane) { _, requested in
            guard let requested else { return }
            selection = requested
            route.requestedPane = nil
        }
        .onAppear {
            if let requested = route.requestedPane {
                selection = requested
                route.requestedPane = nil
            }
        }
        .overlay(alignment: .bottom) { settingsToast }
        .onChange(of: vm.toast) { _, message in
            if let message { A11yAnnouncer.announce(message) }
        }
        .alert(vm.settingsAlert?.title ?? "",
               isPresented: Binding(get: { vm.settingsAlert != nil },
                                    set: { if !$0 { vm.settingsAlert = nil } }),
               presenting: vm.settingsAlert) { alert in
            if let confirmTitle = alert.confirmTitle {
                Button(confirmTitle, role: alert.isDestructive ? .destructive : nil) {
                    alert.onConfirm?()
                }
                Button(L10n.t("Cancel"), role: .cancel) { }
            } else {
                Button(L10n.t("OK"), role: .cancel) { }
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    @ViewBuilder
    private var settingsToast: some View {
        if let toast = vm.toast {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    .a11yDecorative()
                Text(toast).scaledFont(size: 12.5)
            }
            .a11yGroup(label: toast)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline))
            .shadow(radius: 12, y: 6)
            .padding(.bottom, 24)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selection {
        case .general: generalPane
        case .network: networkPane
        case .aggregation: AggregationSettingsPane()
        case .traffic: trafficPane
        case .bittorrent: bittorrentPane
        case .scheduler: SchedulerPane()
        case .rss: RSSPane()
        case .advanced: advancedPane
        case .antivirus: antivirusPane
        case .browser: BrowserIntegrationPane()
        case .remote: RemoteAccessPane()
        case .audit: AuditLogPane()
        case .license: LicensePane()
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        setting(vm, keyPath)
    }

    private func profileBinding<T>(_ keyPath: WritableKeyPath<TrafficProfile, T>) -> Binding<T> {
        Binding(
            get: { vm.settings.selectedProfile[keyPath: keyPath] },
            set: { newValue in
                vm.update { settings in
                    guard let idx = settings.profiles.firstIndex(where: { $0.name == settings.selectedProfileName }) else { return }
                    settings.profiles[idx][keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// Clamped to 1 TB/s only because `Int64(Double)` traps on overflow; the real ceiling is `TrafficProfile.validated()`.
    private func megabytesBinding(_ keyPath: WritableKeyPath<TrafficProfile, Int64>) -> Binding<Double> {
        Binding(
            get: { Double(vm.settings.selectedProfile[keyPath: keyPath]) / 1_048_576 },
            set: { mbPerSec in
                let mb = mbPerSec.isFinite ? min(max(0, mbPerSec), 1_048_576) : 0
                let bytes = Int64(mb * 1_048_576)
                vm.update { settings in
                    guard let idx = settings.profiles.firstIndex(where: { $0.name == settings.selectedProfileName }) else { return }
                    settings.profiles[idx][keyPath: keyPath] = bytes
                }
            }
        )
    }

    private static let generalManagedKeys: [ManagedPolicy.Key] = [
        .defaultFolderRule, .defaultSaveDirectory,
    ]

    private var generalPane: some View {
        PaneScaffold(title: L10n.t("General"), subtitle: L10n.t("Appearance, startup, and where files land.")) {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.generalManagedKeys)

            SetRow(name: L10n.t("Theme"), desc: L10n.t("Pick a look: Frost (light/dark), Dracula, or Nord.")) {
                Picker("", selection: $vm.theme) {
                    ForEach(AppTheme.allCases) { Text(L10n.t($0.rawValue)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
                .accessibilityLabel(L10n.t("Theme"))
            }
            // Only languages that ship a strings table: anything else silently resolves to English.
            SetRow(name: L10n.t("Language"),
                   desc: L10n.t("%@ ship translations today.",
                                L10n.supportedLanguages.map(\.name).joined(separator: ", "))) {
                Dropdown(selection: binding(\.language),
                         items: L10n.supportedLanguages.map { .option($0.name, $0.name) },
                         width: 150)
            }
            SetRow(name: L10n.t("Launch at login"), desc: L10n.t("Start Goel° when you log in.")) {
                SettingSwitch(isOn: binding(\.launchAtLogin))
            }
            SetRow(name: L10n.t("Launch minimized"), desc: L10n.t("Open to the menu bar instead of a window.")) {
                SettingSwitch(isOn: binding(\.launchMinimized))
            }
            SetRow(name: L10n.t("Show in menu bar"),
                   desc: L10n.t("Add a menu-bar item with live ↓/↑ speed and quick controls.")) {
                SettingSwitch(isOn: binding(\.menuBarExtraEnabled))
            }
            SetRow(name: L10n.t("Default download folder"),
                   desc: L10n.t("Choose automatically, by type, by source URL, or fixed.")) {
                Dropdown(selection: binding(\.defaultFolderRule), items: [
                    .option("automatic", L10n.t("Automatic")),
                    .option("byType", L10n.t("By file type")),
                    .option("bySource", L10n.t("By source URL")),
                    .option("fixed", L10n.t("Fixed folder…")),
                ], width: 150)
                .managed(.defaultFolderRule, vm.managedPolicy)
            }
            if vm.settings.defaultFolderRule == "fixed" {
                SetRow(name: L10n.t("Fixed folder"), desc: vm.settings.defaultSaveDirectory) {
                    Button(L10n.t("Choose…")) { chooseDefaultFolder() }
                        .accessibilityLabel(L10n.t("Choose fixed download folder"))
                        .managed(.defaultSaveDirectory, vm.managedPolicy)
                }
            }
            SetRow(name: L10n.t("When a file exists"),
                   desc: L10n.t("Replace it, or keep both by appending “(1)”.")) {
                Picker("", selection: binding(\.existingFileReaction)) {
                    Text(L10n.t("Rename")).tag("rename")
                    Text(L10n.t("Overwrite")).tag("overwrite")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .accessibilityLabel(L10n.t("When a file exists"))
            }
            SetRow(name: L10n.t("Clipboard capture"),
                   desc: L10n.t("Offer to download http(s)/magnet links you copy.")) {
                SettingSwitch(isOn: binding(\.clipboardMonitorEnabled))
            }
            SetRow(name: L10n.t("Max video quality"),
                   desc: L10n.t("Preferred rendition when grabbing an HLS (.m3u8) stream.")) {
                Dropdown(selection: binding(\.hlsMaxHeight), items: [
                    .option(0, L10n.t("Best available")),
                    .option(1080, "1080p"),
                    .option(720, "720p"),
                    .option(480, "480p"),
                    .option(360, "360p"),
                ], width: 150)
            }
            SectionHeader(L10n.t("Media tools"))
            SetRow(name: L10n.t("Download subtitles"),
                   desc: L10n.t("Fetch subtitles alongside yt-dlp video downloads (requires yt-dlp).")) {
                SettingSwitch(isOn: binding(\.subtitleDownloadEnabled))
            }
            if vm.settings.subtitleDownloadEnabled {
                SetRow(name: L10n.t("Subtitle languages"),
                       desc: L10n.t("Comma-separated codes, e.g. “en, es”.")) {
                    SettingText(text: binding(\.subtitleLanguages), width: 140)
                }
                SetRow(name: L10n.t("Include auto-captions"),
                       desc: L10n.t("Fall back to machine-generated captions when no human subtitles exist.")) {
                    SettingSwitch(isOn: binding(\.subtitleIncludeAutoGenerated))
                }
            }
            SetRow(name: L10n.t("ffmpeg path"),
                   desc: L10n.t("Optional. Leave empty to use the copy included with Goel°. Enables Convert / Extract-audio on finished media.")) {
                SettingText(text: binding(\.ffmpegPath), width: 200)
            }
            Text(vm.ffmpegResolutionSummary)
                .scaledFont(size: 10)
                .foregroundStyle(vm.ffmpegUnavailableReason == nil ? Color.secondary : Theme.orange)
                .fixedSize(horizontal: false, vertical: true)
            SetRow(name: L10n.t("Conversions at once"),
                   desc: L10n.t("ffmpeg already uses every core for one job, so running more at "
                       + "the same time makes each one slower without finishing the batch sooner.")) {
                Dropdown(selection: binding(\.mediaConcurrency), items: [
                    .option(1, "1"),
                    .option(2, "2"),
                    .option(3, "3"),
                    .option(4, "4"),
                ], width: 90)
            }
        }
    }

    private func chooseDefaultFolder() {
        if let url = FilePicker.chooseDirectory() {
            vm.setDefaultSaveDirectory(url.path)
        }
    }

    private static let networkManagedKeys: [ManagedPolicy.Key] = [
        .proxyMode, .proxyType, .proxyHost, .proxyPort,
    ]

    private var networkPane: some View {
        PaneScaffold(title: L10n.t("Network"), subtitle: L10n.t("Proxy, timeouts, retries, and authentication.")) {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.networkManagedKeys)

            SectionHeader(L10n.t("Proxy"))
            SetRow(name: L10n.t("Proxy"), desc: L10n.t("Route traffic through a proxy server. Multi-path aggregation is disabled while a system or manual proxy is set.")) {
                Dropdown(selection: binding(\.proxyMode), items: [
                    .option("none", L10n.t("None")),
                    .option("system", L10n.t("System")),
                    .option("manual", L10n.t("Manual")),
                ], width: 150)
                .managed(.proxyMode, vm.managedPolicy)
            }
            if vm.settings.proxyMode == "manual" {
                SetRow(name: L10n.t("Proxy type"), desc: L10n.t("HTTP or SOCKS5 (applies to HTTP/HTTPS downloads).")) {
                    Dropdown(selection: binding(\.proxyType), items: [
                        .option("http", "HTTP"),
                        .option("socks5", "SOCKS5"),
                    ], width: 150)
                    .managed(.proxyType, vm.managedPolicy)
                }
                SetRow(name: L10n.t("Proxy host"), desc: L10n.t("Hostname or IP of the proxy server.")) {
                    SettingText(text: binding(\.proxyHost), width: 160)
                        .managed(.proxyHost, vm.managedPolicy)
                }
                SetRow(name: L10n.t("Proxy port"), desc: L10n.t("Port the proxy listens on.")) {
                    SettingInt(value: binding(\.proxyPort))
                        .managed(.proxyPort, vm.managedPolicy)
                }
            }
            SetRow(name: L10n.t("Connection timeout"), desc: L10n.t("Seconds before a stalled connection drops.")) {
                SettingDouble(value: binding(\.connectionTimeout))
            }
            SetRow(name: L10n.t("Retry count"), desc: L10n.t("Attempts before marking a download failed.")) {
                SettingInt(value: binding(\.retryCount))
            }
            SetRow(name: L10n.t("Retry interval"), desc: L10n.t("Seconds to wait between retries.")) {
                SettingDouble(value: binding(\.retryInterval))
            }
            SetRow(name: L10n.t("Auto-retry failed downloads"),
                   desc: L10n.t("Automatically re-queue a failed download and try again, with an exponential backoff between attempts.")) {
                SettingSwitch(isOn: binding(\.autoRetryEnabled))
            }
            if vm.settings.autoRetryEnabled {
                SetRow(name: L10n.t("Auto-retry attempts"),
                       desc: L10n.t("How many times to retry before leaving it failed for a manual retry.")) {
                    SettingInt(value: binding(\.autoRetryMaxAttempts))
                }
            }
            SetRow(name: L10n.t("Custom user-agent"), desc: L10n.t("Sent with HTTP requests.")) {
                SettingText(text: binding(\.userAgent), width: 160)
            }
            SetRow(name: L10n.t("Cookie / auth handling"), desc: L10n.t("Reuse cookies for protected downloads.")) {
                SettingSwitch(isOn: binding(\.cookieAuthEnabled))
            }
            SetRow(name: L10n.t("Re-download when remote changes"),
                   desc: L10n.t("Periodically re-check finished HTTP downloads and fetch again if the server's file changed.")) {
                SettingSwitch(isOn: binding(\.autoRedownloadOnRemoteChange))
            }
            SectionHeader(L10n.t("Network awareness"))
            SetRow(name: L10n.t("Pause on expensive networks"),
                   desc: L10n.t("Hold downloads while on a personal hotspot; resume automatically after.")) {
                SettingSwitch(isOn: binding(\.pauseOnExpensiveNetwork))
            }
            SetRow(name: L10n.t("Pause in Low Data Mode"),
                   desc: L10n.t("Hold downloads while the connection is constrained.")) {
                SettingSwitch(isOn: binding(\.pauseOnConstrainedNetwork))
            }
            CredentialsSection()
        }
    }

    private static let trafficManagedKeys: [ManagedPolicy.Key] = [
        .selectedProfileName, .maxDownloadBytesPerSec, .maxUploadBytesPerSec,
    ]

    private var trafficPane: some View {
        PaneScaffold(title: L10n.t("Traffic Limits"),
                     subtitle: L10n.t("Three switchable profiles. The status-bar snail toggles Unlimited vs the active profile.")) {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.trafficManagedKeys)

            HStack(spacing: 10) {
                ForEach(vm.settings.profiles) { profile in
                    profileCard(profile)
                }
            }
            .padding(.bottom, 8)

            let active = vm.settings.selectedProfile
            SectionHeader(L10n.t("Editing: %@ profile", active.name))
            // Deliberately not `.managed(…)`: a forced ceiling is a clamp, not an assignment.
            SetRow(name: L10n.t("Max download speed"), desc: L10n.t("0 = unlimited.")) {
                HStack(spacing: 4) {
                    SettingDouble(value: megabytesBinding(\.maxDownloadBytesPerSec), width: 70)
                    Text(L10n.t("MB/s")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            SetRow(name: L10n.t("Max upload speed"), desc: "") {
                HStack(spacing: 4) {
                    SettingDouble(value: megabytesBinding(\.maxUploadBytesPerSec), width: 70)
                    Text(L10n.t("MB/s")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            SetRow(name: L10n.t("Max connections (global)"), desc: "") {
                SettingInt(value: profileBinding(\.maxConnections))
            }
            SetRow(name: L10n.t("Max connections per server"), desc: "") {
                SettingInt(value: profileBinding(\.maxConnectionsPerServer))
            }
            SetRow(name: L10n.t("Max simultaneous downloads"), desc: "") {
                SettingInt(value: profileBinding(\.maxSimultaneousDownloads))
            }
            SetRow(name: L10n.t("Stop seeding at ratio"), desc: "") {
                SettingDouble(value: profileBinding(\.seedRatioLimit))
            }
            SetRow(name: L10n.t("Max metadata-resolution downloads"), desc: L10n.t("Concurrent “requesting info” magnets.")) {
                SettingInt(value: profileBinding(\.maxMetadataResolutions))
            }
            SetRow(name: L10n.t("Additional connections to optimize speed"), desc: "") {
                SettingSwitch(isOn: profileBinding(\.enableExtraConnections))
            }
        }
    }

    private func profileCard(_ profile: TrafficProfile) -> some View {
        let selected = profile.name == vm.settings.selectedProfileName
        let dot: Color = profile.name == "Low" ? Theme.green : profile.name == "High" ? Theme.red : Theme.orange
        return Button {
            vm.setProfile(profile.name)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text(profile.name).font(.system(size: 13, weight: .semibold))
                }
                Text("↓ \(profile.isDownloadUnlimited ? L10n.t("Unlimited") : profile.maxDownloadBytesPerSec.byteString + "/s")\n↑ \(profile.maxUploadBytesPerSec <= 0 ? L10n.t("Unlimited") : profile.maxUploadBytesPerSec.byteString + "/s")\n\(L10n.t("%1$@ conns · %2$@ active", String(profile.maxConnections), String(profile.maxSimultaneousDownloads)))\n\(L10n.t("seed to %@×", String(format: "%.1f", profile.seedRatioLimit)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Theme.accent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.accent : Theme.hairline, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .managed(.selectedProfileName, vm.managedPolicy)
    }

    private var bittorrentPane: some View {
        PaneScaffold(title: L10n.t("BitTorrent"), subtitle: L10n.t("Protocol, privacy, and watch-folder behavior.")) {
            SetRow(name: L10n.t("Default torrent client"), desc: L10n.t("Own magnet: links and .torrent files.")) {
                SettingSwitch(isOn: binding(\.btMakeDefaultClient))
            }
            SetRow(name: L10n.t("Auto-delete .torrent when done"), desc: L10n.t("Remove the source file after completion.")) {
                SettingSwitch(isOn: binding(\.btAutoDeleteTorrent))
            }
            SetRow(name: L10n.t("Watch folder for .torrent files"), desc: L10n.t("Auto-add new torrents that appear in a folder.")) {
                SettingSwitch(isOn: binding(\.btWatchFolderEnabled))
            }
            // The watch is armed by `btWatchFolderPath`, not the switch above, and this chooser is its only writer.
            if vm.settings.btWatchFolderEnabled {
                SetRow(name: L10n.t("Watched folder"),
                       desc: vm.settings.btWatchFolderPath.isEmpty
                           ? L10n.t("No folder chosen — nothing is being watched.")
                           : vm.settings.btWatchFolderPath) {
                    Button(L10n.t("Choose…")) {
                        if let url = FilePicker.chooseDirectory() {
                            vm.update { $0.btWatchFolderPath = url.path }
                        }
                    }
                    .accessibilityLabel(L10n.t("Choose watched torrent folder"))
                }
                SetRow(name: L10n.t("Start watched torrents without confirmation"), desc: "") {
                    SettingSwitch(isOn: binding(\.btWatchStartWithoutConfirmation))
                }
            }
            SetRow(name: L10n.t("Encryption mode"), desc: L10n.t("Protocol encryption for peer connections.")) {
                Dropdown(selection: binding(\.btEncryptionMode), items: [
                    .option("prefer", L10n.t("Prefer")),
                    .option("require", L10n.t("Require")),
                    .option("disable", L10n.t("Disable")),
                ], width: 140)
            }
            SetRow(name: L10n.t("Enable DHT"), desc: L10n.t("Find peers without a tracker.")) {
                SettingSwitch(isOn: binding(\.btEnableDHT))
            }
            SetRow(name: L10n.t("Enable PeX"), desc: L10n.t("Exchange peers with other clients.")) {
                SettingSwitch(isOn: binding(\.btEnablePeX))
            }
            SetRow(name: L10n.t("Enable Local Peer Discovery"), desc: L10n.t("Find peers on the local network.")) {
                SettingSwitch(isOn: binding(\.btEnableLPD))
            }
            SetRow(name: L10n.t("Enable µTP"), desc: L10n.t("BitTorrent over UDP for better congestion control.")) {
                SettingSwitch(isOn: binding(\.btEnableUTP))
            }
            if let gap = swarmProxyGap {
                Label(L10n.t(gap.rawValue), systemImage: "exclamationmark.shield.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Left unstated, a user who set a proxy would assume their swarm peers go through it — they do not.
    private var swarmProxyGap: SwarmProxy.Gap? {
        SwarmProxy.resolve(NetworkGuard.ProxySpec(mode: vm.settings.proxyMode,
                                                  type: vm.settings.proxyType,
                                                  host: vm.settings.proxyHost,
                                                  port: vm.settings.proxyPort)).gap
    }

    private static let updatesManagedKeys: [ManagedPolicy.Key] = [
        .autoCheckUpdates, .updateFeedURL,
    ]

    private var advancedPane: some View {
        PaneScaffold(title: L10n.t("Advanced"), subtitle: L10n.t("Notifications, power management, and backup.")) {
            SectionHeader(L10n.t("Notifications"))
            SetRow(name: L10n.t("On download added"), desc: "") { SettingSwitch(isOn: binding(\.notifyOnAdded)) }
            SetRow(name: L10n.t("On download completed"), desc: "") { SettingSwitch(isOn: binding(\.notifyOnCompleted)) }
            SetRow(name: L10n.t("On download failed"), desc: "") { SettingSwitch(isOn: binding(\.notifyOnFailed)) }
            SetRow(name: L10n.t("Only when app is inactive"), desc: "") { SettingSwitch(isOn: binding(\.notifyOnlyWhenInactive)) }
            SetRow(name: L10n.t("Play sound"), desc: "") { SettingSwitch(isOn: binding(\.notificationSound)) }
            SectionHeader(L10n.t("Power management"))
            SetRow(name: L10n.t("Prevent sleep during active downloads"), desc: "") { SettingSwitch(isOn: binding(\.preventSleepWhileDownloading)) }
            SetRow(name: L10n.t("Allow sleep if downloads can resume later"), desc: "") { SettingSwitch(isOn: binding(\.allowSleepIfResumable)) }
            SetRow(name: L10n.t("Allow sleep while seeding"), desc: "") { SettingSwitch(isOn: binding(\.allowSleepWhileSeeding)) }
            SetRow(name: L10n.t("Pause downloads below battery threshold"), desc: "") {
                HStack(spacing: 4) {
                    // The getter must report 0 while off: showing the stored value made re-typing it a dropped no-op.
                    SettingInt(value: Binding(
                        get: {
                            vm.settings.pauseBelowBatteryThreshold
                                ? vm.settings.batteryThresholdPercent : 0
                        },
                        set: { newValue in
                            vm.update {
                                $0.batteryThresholdPercent = newValue
                                $0.pauseBelowBatteryThreshold = newValue > 0
                            }
                        }
                    ), width: 48)
                    Text(L10n.t("%")).font(.system(size: 13))
                }
            }
            SetRow(name: L10n.t("Don't seed on battery"), desc: "") { SettingSwitch(isOn: binding(\.dontSeedOnBattery)) }
            SectionHeader(L10n.t("Post-download actions"))
            SetRow(name: L10n.t("Auto-extract archives"), desc: L10n.t("Unpack finished .zip downloads next to the file.")) {
                SettingSwitch(isOn: binding(\.postDownloadExtractArchives))
            }
            SetRow(name: L10n.t("Run a script on completion"),
                   desc: L10n.t("An executable script; %path% in the arguments becomes the finished file.")) {
                SettingSwitch(isOn: binding(\.postDownloadScriptEnabled))
            }
            if vm.settings.postDownloadScriptEnabled {
                SetRow(name: L10n.t("Script path"), desc: L10n.t("Must be executable (not “bash script.sh”).")) {
                    SettingText(text: binding(\.postDownloadScriptPath), width: 200)
                }
                SetRow(name: L10n.t("Arguments"), desc: "") {
                    SettingText(text: binding(\.postDownloadScriptArgs), width: 140)
                }
            }
            SectionHeader(L10n.t("Backup"))
            SetRow(name: L10n.t("Periodically back up the download list"), desc: "") { SettingSwitch(isOn: binding(\.backupEnabled)) }
            SetRow(name: L10n.t("Backup interval"), desc: "") {
                Dropdown(selection: binding(\.backupIntervalHours), items: [
                    .option(1, L10n.t("Hourly")),
                    .option(24, L10n.t("Daily")),
                    .option(168, L10n.t("Weekly")),
                ], width: 140)
            }
            SetRow(name: L10n.t("Keep"), desc: L10n.t("Older backups are pruned automatically.")) {
                Dropdown(selection: binding(\.backupKeepCount), items: [
                    .option(5, L10n.t("5 backups")),
                    .option(20, L10n.t("20 backups")),
                    .option(50, L10n.t("50 backups")),
                ], width: 140)
            }
            SectionHeader(L10n.t("Updates"))
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.updatesManagedKeys)
            SetRow(name: L10n.t("Check for updates automatically"), desc: L10n.t("Once at launch.")) {
                SettingSwitch(isOn: binding(\.autoCheckUpdates))
                    .managed(.autoCheckUpdates, vm.managedPolicy)
            }
            SetRow(name: L10n.t("Release feed URL"),
                   desc: L10n.t("A GitHub releases API URL (or compatible JSON feed).")) {
                SettingText(text: binding(\.updateFeedURL), width: 220)
                    .managed(.updateFeedURL, vm.managedPolicy)
            }
            SetRow(name: "", desc: "") {
                Button(L10n.t("Check Now")) { vm.checkForUpdates() }
            }
            diagnosticsSection
        }
    }

    /// No telemetry: assembled in memory on demand, handed straight to the user, never sent or stored.
    @ViewBuilder
    private var diagnosticsSection: some View {
        SectionHeader(L10n.t("Diagnostics"))
        SetRow(name: L10n.t("Support report"),
               desc: L10n.t("Versions, engine states, task counts, and a redacted settings dump — "
                   + "no URLs, file names, paths, or credentials. Nothing is ever sent automatically.")) {
            HStack(spacing: 8) {
                Button(L10n.t("Copy")) { copyDiagnostics() }
                Button(L10n.t("Export…")) { exportDiagnostics() }
            }
        }
        Text(L10n.t("Withheld from every report: %@.",
                    DiagnosticsRedaction.withheldSettingsKeys.sorted().joined(separator: ", ")))
            .scaledFont(size: 10)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func makeDiagnostics() -> DiagnosticsBundle {
        DiagnosticsBundle.make(settings: vm.settings,
                               tasks: vm.tasks,
                               runningEngineKinds: vm.runningEngineKinds)
    }

    private func copyDiagnostics() {
        vm.copyToPasteboard(makeDiagnostics().plainText)
        vm.toastNow(L10n.t("Diagnostics copied — paste it into your bug report"))
    }

    private func exportDiagnostics() {
        guard let url = FilePicker.save(name: "Goel-diagnostics.json", type: .json) else { return }
        do {
            try makeDiagnostics().jsonData().write(to: url, options: .atomic)
            vm.toastNow(L10n.t("Diagnostics saved"))
        } catch {
            vm.settingsMessage(L10n.t("Export Failed"),
                               L10n.t("Couldn’t write the diagnostics report to that location."))
        }
    }

    private var antivirusPane: some View {
        PaneScaffold(title: L10n.t("Antivirus"), subtitle: L10n.t("Run an external scanner on finished files. Optional, low priority on macOS.")) {
            SetRow(name: L10n.t("Scan finished files"), desc: "") { SettingSwitch(isOn: binding(\.antivirusEnabled)) }
            SetRow(name: L10n.t("Scanner"), desc: "") {
                Dropdown(selection: binding(\.antivirusScanner), items: [
                    .option("", L10n.t("Configure manually…")),
                    .option("ClamAV", "ClamAV"),
                ], width: 170)
            }
            SetRow(name: L10n.t("Executable path"), desc: "") {
                SettingText(text: binding(\.antivirusExecutablePath), width: 180)
            }
            SetRow(name: L10n.t("Argument template"), desc: L10n.t("%path% is replaced with the file.")) {
                SettingText(text: binding(\.antivirusArgumentTemplate), width: 120)
            }
        }
    }
}
