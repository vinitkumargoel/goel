import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The Preferences window. General / Network / Traffic Limits / BitTorrent / Advanced are fully
/// functional and persist through `vm.settings`; Antivirus persists but ships its scanner later.
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

        /// Panes that carry the dimmed "soon" badge in the sidebar. Every pane
        /// is live now; the badge remains only for genuinely-parked work.
        var comingSoon: Bool { false }

    }

    @State private var selection: Pane = .general

    /// Lets the command palette (and the empty state's shortcuts) open Settings
    /// directly on a named pane instead of wherever it was last left.
    @ObservedObject private var route = SettingsRoute.shared

    var body: some View {
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $selection) { pane in
                Label {
                    HStack {
                        Text(pane.rawValue)
                        if pane.comingSoon {
                            Spacer()
                            Text("soon")
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
        // A pane requested from elsewhere (⌘K, the empty state) wins over the remembered selection. The
        // request is cleared once consumed so asking for the same pane twice still navigates.
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
        // Settings is its own window and doesn't carry the main window's overlays — so surface feedback
        // here: errors and confirmations as a modal alert, successes as a bottom banner.
        .overlay(alignment: .bottom) { settingsToast }
        // The banner never takes focus, so without an announcement a
        // screen-reader user gets no confirmation that a setting took effect.
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
                Button("Cancel", role: .cancel) { }
            } else {
                Button("OK", role: .cancel) { }
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    /// The same success banner the main window shows, mirrored here so toasts
    /// raised by settings panes (copied, feed added, …) are visible in Settings.
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

    // MARK: Settings bindings

    /// A two-way binding into an `AppSettings` field that commits through ``AppViewModel/update(_:)``
    /// so every edit persists and reaches the core. Forwards to the shared ``setting(_:_:)``.
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        setting(vm, keyPath)
    }

    /// A binding into a field of the *currently selected* traffic profile. Edits write back into
    /// `settings.profiles`, so the active profile's limits are editable and re-applied to the engines.
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

    /// A MB/s view onto a profile's byte/sec field. Clamped to 1 TB/s on the way in only because
    /// `Int64(Double)` **traps** on overflow — the real ceiling is ``TrafficProfile/validated()``.
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

    // MARK: General

    /// The ``ManagedPolicy`` keys this pane renders a control for, so the notice
    /// at the top appears exactly when one of them is locked.
    private static let generalManagedKeys: [ManagedPolicy.Key] = [
        .defaultFolderRule, .defaultSaveDirectory,
    ]

    private var generalPane: some View {
        PaneScaffold(title: "General", subtitle: "Appearance, startup, and where files land.") {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.generalManagedKeys)

            SetRow(name: "Theme", desc: "Pick a look: Frost (light/dark), Dracula, or Nord.") {
                Picker("", selection: $vm.theme) {
                    ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
                // `labelsHidden()` hides the name from VoiceOver too; the
                // `SetRow` environment only reaches the `Setting*` wrappers.
                .accessibilityLabel("Theme")
            }
            // Offer exactly the languages that ship a strings table. The list used to include ones with none,
            // which silently resolved to English; ``AppSettings/validated()`` repairs a value persisted then.
            SetRow(name: "Language", desc: "English and Deutsch ship translations today.") {
                Dropdown(selection: binding(\.language),
                         items: L10n.supportedLanguages.map { .option($0.name, $0.name) },
                         width: 150)
            }
            SetRow(name: "Launch at login", desc: "Start Goel° when you log in.") {
                SettingSwitch(isOn: binding(\.launchAtLogin))
            }
            SetRow(name: "Launch minimized", desc: "Open to the menu bar instead of a window.") {
                SettingSwitch(isOn: binding(\.launchMinimized))
            }
            SetRow(name: "Show in menu bar",
                   desc: "Add a menu-bar item with live ↓/↑ speed and quick controls.") {
                SettingSwitch(isOn: binding(\.menuBarExtraEnabled))
            }
            SetRow(name: "Default download folder",
                   desc: "Choose automatically, by type, by source URL, or fixed.") {
                Dropdown(selection: binding(\.defaultFolderRule), items: [
                    .option("automatic", "Automatic"),
                    .option("byType", "By file type"),
                    .option("bySource", "By source URL"),
                    .option("fixed", "Fixed folder…"),
                ], width: 150)
                .managed(.defaultFolderRule, vm.managedPolicy)
            }
            // For the "Fixed folder" rule, surface the actual destination and a
            // chooser so the existing default-save-directory feature stays usable.
            if vm.settings.defaultFolderRule == "fixed" {
                SetRow(name: "Fixed folder", desc: vm.settings.defaultSaveDirectory) {
                    // A forced path is re-applied by the overlay the moment the picker commits, so an enabled button
                    // would accept a folder and leave the row reading the old one. Say who owns it.
                    Button("Choose…") { chooseDefaultFolder() }
                        .accessibilityLabel("Choose fixed download folder")
                        .managed(.defaultSaveDirectory, vm.managedPolicy)
                }
            }
            SetRow(name: "When a file exists",
                   desc: "Replace it, or keep both by appending “(1)”.") {
                Picker("", selection: binding(\.existingFileReaction)) {
                    Text("Rename").tag("rename")
                    Text("Overwrite").tag("overwrite")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .accessibilityLabel("When a file exists")
            }
            SetRow(name: "Clipboard capture",
                   desc: "Offer to download http(s)/magnet links you copy.") {
                SettingSwitch(isOn: binding(\.clipboardMonitorEnabled))
            }
            SetRow(name: "Max video quality",
                   desc: "Preferred rendition when grabbing an HLS (.m3u8) stream.") {
                Dropdown(selection: binding(\.hlsMaxHeight), items: [
                    .option(0, "Best available"),
                    .option(1080, "1080p"),
                    .option(720, "720p"),
                    .option(480, "480p"),
                    .option(360, "360p"),
                ], width: 150)
            }
            SectionHeader("Media tools")
            SetRow(name: "Download subtitles",
                   desc: "Fetch subtitles alongside yt-dlp video downloads (requires yt-dlp).") {
                SettingSwitch(isOn: binding(\.subtitleDownloadEnabled))
            }
            if vm.settings.subtitleDownloadEnabled {
                SetRow(name: "Subtitle languages",
                       desc: "Comma-separated codes, e.g. “en, es”.") {
                    SettingText(text: binding(\.subtitleLanguages), width: 140)
                }
                SetRow(name: "Include auto-captions",
                       desc: "Fall back to machine-generated captions when no human subtitles exist.") {
                    SettingSwitch(isOn: binding(\.subtitleIncludeAutoGenerated))
                }
            }
            SetRow(name: "ffmpeg path",
                   desc: "Optional. Leave empty to use the copy included with Goel°. Enables Convert / Extract-audio on finished media.") {
                SettingText(text: binding(\.ffmpegPath), width: 200)
            }
            // Show which binary actually won (override → bundled → system), so a typo'd path or a missing
            // bundle is visible where it is configured rather than only when a conversion fails.
            Text(vm.ffmpegResolutionSummary)
                .scaledFont(size: 10)
                .foregroundStyle(vm.ffmpegUnavailableReason == nil ? Color.secondary : Theme.orange)
                .fixedSize(horizontal: false, vertical: true)
            SetRow(name: "Conversions at once",
                   desc: "ffmpeg already uses every core for one job, so running more at "
                       + "the same time makes each one slower without finishing the batch sooner.") {
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

    // MARK: Network

    /// The ``ManagedPolicy`` keys this pane renders a control for. `proxyHost`/`proxyPort` appear only
    /// under "Manual" but belong to the set anyway — the notice is about the pane, not the moment.
    private static let networkManagedKeys: [ManagedPolicy.Key] = [
        .proxyMode, .proxyType, .proxyHost, .proxyPort,
    ]

    private var networkPane: some View {
        PaneScaffold(title: "Network", subtitle: "Proxy, timeouts, retries, and authentication.") {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.networkManagedKeys)

            SectionHeader("Proxy")
            SetRow(name: "Proxy", desc: "Route traffic through a proxy server. Multi-path aggregation is disabled while a system or manual proxy is set.") {
                Dropdown(selection: binding(\.proxyMode), items: [
                    .option("none", "None"),
                    .option("system", "System"),
                    .option("manual", "Manual"),
                ], width: 150)
                .managed(.proxyMode, vm.managedPolicy)
            }
            if vm.settings.proxyMode == "manual" {
                SetRow(name: "Proxy type", desc: "HTTP or SOCKS5 (applies to HTTP/HTTPS downloads).") {
                    Dropdown(selection: binding(\.proxyType), items: [
                        .option("http", "HTTP"),
                        .option("socks5", "SOCKS5"),
                    ], width: 150)
                    .managed(.proxyType, vm.managedPolicy)
                }
                SetRow(name: "Proxy host", desc: "Hostname or IP of the proxy server.") {
                    SettingText(text: binding(\.proxyHost), width: 160)
                        .managed(.proxyHost, vm.managedPolicy)
                }
                SetRow(name: "Proxy port", desc: "Port the proxy listens on.") {
                    SettingInt(value: binding(\.proxyPort))
                        .managed(.proxyPort, vm.managedPolicy)
                }
            }
            SetRow(name: "Connection timeout", desc: "Seconds before a stalled connection drops.") {
                SettingDouble(value: binding(\.connectionTimeout))
            }
            SetRow(name: "Retry count", desc: "Attempts before marking a download failed.") {
                SettingInt(value: binding(\.retryCount))
            }
            SetRow(name: "Retry interval", desc: "Seconds to wait between retries.") {
                SettingDouble(value: binding(\.retryInterval))
            }
            SetRow(name: "Auto-retry failed downloads",
                   desc: "Automatically re-queue a failed download and try again, with an exponential backoff between attempts.") {
                SettingSwitch(isOn: binding(\.autoRetryEnabled))
            }
            if vm.settings.autoRetryEnabled {
                SetRow(name: "Auto-retry attempts",
                       desc: "How many times to retry before leaving it failed for a manual retry.") {
                    SettingInt(value: binding(\.autoRetryMaxAttempts))
                }
            }
            SetRow(name: "Custom user-agent", desc: "Sent with HTTP requests.") {
                SettingText(text: binding(\.userAgent), width: 160)
            }
            SetRow(name: "Cookie / auth handling", desc: "Reuse cookies for protected downloads.") {
                SettingSwitch(isOn: binding(\.cookieAuthEnabled))
            }
            SetRow(name: "Re-download when remote changes",
                   desc: "Periodically re-check finished HTTP downloads and fetch again if the server's file changed.") {
                SettingSwitch(isOn: binding(\.autoRedownloadOnRemoteChange))
            }
            SectionHeader("Network awareness")
            SetRow(name: "Pause on expensive networks",
                   desc: "Hold downloads while on a personal hotspot; resume automatically after.") {
                SettingSwitch(isOn: binding(\.pauseOnExpensiveNetwork))
            }
            SetRow(name: "Pause in Low Data Mode",
                   desc: "Hold downloads while the connection is constrained.") {
                SettingSwitch(isOn: binding(\.pauseOnConstrainedNetwork))
            }
            CredentialsSection()
        }
    }

    // MARK: Traffic Limits

    /// The ``ManagedPolicy`` keys this pane renders a control for. The two byte ceilings are included
    /// though their fields stay editable, because a value that snaps back needs the same explanation.
    private static let trafficManagedKeys: [ManagedPolicy.Key] = [
        .selectedProfileName, .maxDownloadBytesPerSec, .maxUploadBytesPerSec,
    ]

    private var trafficPane: some View {
        PaneScaffold(title: "Traffic Limits",
                     subtitle: "Three switchable profiles. The status-bar snail toggles Unlimited vs the active profile.") {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.trafficManagedKeys)

            HStack(spacing: 10) {
                ForEach(vm.settings.profiles) { profile in
                    profileCard(profile)
                }
            }
            .padding(.bottom, 8)

            let active = vm.settings.selectedProfile
            SectionHeader("Editing: \(active.name) profile")
            // The two speed fields are deliberately not `.managed(…)`: a forced ceiling is applied as a
            // clamp, not an assignment, so asking for less than the fleet cap is still the user's call.
            SetRow(name: "Max download speed", desc: "0 = unlimited.") {
                HStack(spacing: 4) {
                    SettingDouble(value: megabytesBinding(\.maxDownloadBytesPerSec), width: 70)
                    Text("MB/s").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            SetRow(name: "Max upload speed", desc: "") {
                HStack(spacing: 4) {
                    SettingDouble(value: megabytesBinding(\.maxUploadBytesPerSec), width: 70)
                    Text("MB/s").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            SetRow(name: "Max connections (global)", desc: "") {
                SettingInt(value: profileBinding(\.maxConnections))
            }
            SetRow(name: "Max connections per server", desc: "") {
                SettingInt(value: profileBinding(\.maxConnectionsPerServer))
            }
            SetRow(name: "Max simultaneous downloads", desc: "") {
                SettingInt(value: profileBinding(\.maxSimultaneousDownloads))
            }
            SetRow(name: "Stop seeding at ratio", desc: "") {
                SettingDouble(value: profileBinding(\.seedRatioLimit))
            }
            SetRow(name: "Max metadata-resolution downloads", desc: "Concurrent “requesting info” magnets.") {
                SettingInt(value: profileBinding(\.maxMetadataResolutions))
            }
            SetRow(name: "Additional connections to optimize speed", desc: "") {
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
                Text("↓ \(profile.isDownloadUnlimited ? "Unlimited" : profile.maxDownloadBytesPerSec.byteString + "/s")\n↑ \(profile.maxUploadBytesPerSec <= 0 ? "Unlimited" : profile.maxUploadBytesPerSec.byteString + "/s")\n\(profile.maxConnections) conns · \(profile.maxSimultaneousDownloads) active\nseed to \(String(format: "%.1f", profile.seedRatioLimit))×")
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
        // `selectedProfileName` is assigned outright by the overlay, so a card tapped under a forced
        // profile would highlight for one frame and jump back. Better to show it as the admin's choice.
        .managed(.selectedProfileName, vm.managedPolicy)
    }

    // MARK: BitTorrent

    private var bittorrentPane: some View {
        PaneScaffold(title: "BitTorrent", subtitle: "Protocol, privacy, and watch-folder behavior.") {
            SetRow(name: "Default torrent client", desc: "Own magnet: links and .torrent files.") {
                SettingSwitch(isOn: binding(\.btMakeDefaultClient))
            }
            SetRow(name: "Auto-delete .torrent when done", desc: "Remove the source file after completion.") {
                SettingSwitch(isOn: binding(\.btAutoDeleteTorrent))
            }
            SetRow(name: "Watch folder for .torrent files", desc: "Auto-add new torrents that appear in a folder.") {
                SettingSwitch(isOn: binding(\.btWatchFolderEnabled))
            }
            // The watch is armed by `btWatchFolderPath`, not the switch above, and this chooser is that
            // path's only writer — without it the feature could not be enabled by any user.
            if vm.settings.btWatchFolderEnabled {
                SetRow(name: "Watched folder",
                       desc: vm.settings.btWatchFolderPath.isEmpty
                           ? "No folder chosen — nothing is being watched."
                           : vm.settings.btWatchFolderPath) {
                    Button("Choose…") {
                        if let url = FilePicker.chooseDirectory() {
                            vm.update { $0.btWatchFolderPath = url.path }
                        }
                    }
                    .accessibilityLabel("Choose watched torrent folder")
                }
                SetRow(name: "Start watched torrents without confirmation", desc: "") {
                    SettingSwitch(isOn: binding(\.btWatchStartWithoutConfirmation))
                }
            }
            SetRow(name: "Encryption mode", desc: "Protocol encryption for peer connections.") {
                Dropdown(selection: binding(\.btEncryptionMode), items: [
                    .option("prefer", "Prefer"),
                    .option("require", "Require"),
                    .option("disable", "Disable"),
                ], width: 140)
            }
            SetRow(name: "Enable DHT", desc: "Find peers without a tracker.") {
                SettingSwitch(isOn: binding(\.btEnableDHT))
            }
            SetRow(name: "Enable PeX", desc: "Exchange peers with other clients.") {
                SettingSwitch(isOn: binding(\.btEnablePeX))
            }
            SetRow(name: "Enable Local Peer Discovery", desc: "Find peers on the local network.") {
                SettingSwitch(isOn: binding(\.btEnableLPD))
            }
            SetRow(name: "Enable µTP", desc: "BitTorrent over UDP for better congestion control.") {
                SettingSwitch(isOn: binding(\.btEnableUTP))
            }
            if let gap = swarmProxyGap {
                Label(gap.rawValue, systemImage: "exclamationmark.shield.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Why the configured proxy doesn't fully cover the torrent swarm. Stated rather than left
    /// silent: a user who set a proxy and sees nothing would assume their peers go through it.
    private var swarmProxyGap: SwarmProxy.Gap? {
        SwarmProxy.resolve(NetworkGuard.ProxySpec(mode: vm.settings.proxyMode,
                                                  type: vm.settings.proxyType,
                                                  host: vm.settings.proxyHost,
                                                  port: vm.settings.proxyPort)).gap
    }

    // MARK: Advanced

    /// The ``ManagedPolicy`` keys the Advanced pane renders a control for — all
    /// of them in the Updates section.
    private static let updatesManagedKeys: [ManagedPolicy.Key] = [
        .autoCheckUpdates, .updateFeedURL,
    ]

    private var advancedPane: some View {
        PaneScaffold(title: "Advanced", subtitle: "Notifications, power management, and backup.") {
            SectionHeader("Notifications")
            SetRow(name: "On download added", desc: "") { SettingSwitch(isOn: binding(\.notifyOnAdded)) }
            SetRow(name: "On download completed", desc: "") { SettingSwitch(isOn: binding(\.notifyOnCompleted)) }
            SetRow(name: "On download failed", desc: "") { SettingSwitch(isOn: binding(\.notifyOnFailed)) }
            SetRow(name: "Only when app is inactive", desc: "") { SettingSwitch(isOn: binding(\.notifyOnlyWhenInactive)) }
            SetRow(name: "Play sound", desc: "") { SettingSwitch(isOn: binding(\.notificationSound)) }
            SectionHeader("Power management")
            SetRow(name: "Prevent sleep during active downloads", desc: "") { SettingSwitch(isOn: binding(\.preventSleepWhileDownloading)) }
            SetRow(name: "Allow sleep if downloads can resume later", desc: "") { SettingSwitch(isOn: binding(\.allowSleepIfResumable)) }
            SetRow(name: "Allow sleep while seeding", desc: "") { SettingSwitch(isOn: binding(\.allowSleepWhileSeeding)) }
            SetRow(name: "Pause downloads below battery threshold", desc: "") {
                HStack(spacing: 4) {
                    // A positive threshold enables pause-on-battery; 0 disables it — one control, both fields. The
                    // getter reports 0 while off, because showing the stored 20 made re-typing 20 a dropped no-op.
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
                    Text("%").font(.system(size: 13))
                }
            }
            SetRow(name: "Don't seed on battery", desc: "") { SettingSwitch(isOn: binding(\.dontSeedOnBattery)) }
            SectionHeader("Post-download actions")
            SetRow(name: "Auto-extract archives", desc: "Unpack finished .zip downloads next to the file.") {
                SettingSwitch(isOn: binding(\.postDownloadExtractArchives))
            }
            SetRow(name: "Run a script on completion",
                   desc: "An executable script; %path% in the arguments becomes the finished file.") {
                SettingSwitch(isOn: binding(\.postDownloadScriptEnabled))
            }
            if vm.settings.postDownloadScriptEnabled {
                SetRow(name: "Script path", desc: "Must be executable (not “bash script.sh”).") {
                    SettingText(text: binding(\.postDownloadScriptPath), width: 200)
                }
                SetRow(name: "Arguments", desc: "") {
                    SettingText(text: binding(\.postDownloadScriptArgs), width: 140)
                }
            }
            SectionHeader("Backup")
            SetRow(name: "Periodically back up the download list", desc: "") { SettingSwitch(isOn: binding(\.backupEnabled)) }
            SetRow(name: "Backup interval", desc: "") {
                Dropdown(selection: binding(\.backupIntervalHours), items: [
                    .option(1, "Hourly"),
                    .option(24, "Daily"),
                    .option(168, "Weekly"),
                ], width: 140)
            }
            SetRow(name: "Keep", desc: "Older backups are pruned automatically.") {
                Dropdown(selection: binding(\.backupKeepCount), items: [
                    .option(5, "5 backups"),
                    .option(20, "20 backups"),
                    .option(50, "50 backups"),
                ], width: 140)
            }
            SectionHeader("Updates")
            // Scoped to the section rather than the pane: Updates is the only part of Advanced an
            // administrator can reach, and a top banner would imply the notification and power rows were locked.
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.updatesManagedKeys)
            SetRow(name: "Check for updates automatically", desc: "Once at launch.") {
                SettingSwitch(isOn: binding(\.autoCheckUpdates))
                    .managed(.autoCheckUpdates, vm.managedPolicy)
            }
            SetRow(name: "Release feed URL",
                   desc: "A GitHub releases API URL (or compatible JSON feed).") {
                SettingText(text: binding(\.updateFeedURL), width: 220)
                    .managed(.updateFeedURL, vm.managedPolicy)
            }
            SetRow(name: "", desc: "") {
                Button("Check Now") { vm.checkForUpdates() }
            }
            diagnosticsSection
        }
    }

    // MARK: Diagnostics

    /// The support report, in the only shape "no telemetry" permits: assembled in memory on a button
    /// press, handed straight to the user, forgotten. The save panel is deliberate friction.
    @ViewBuilder
    private var diagnosticsSection: some View {
        SectionHeader("Diagnostics")
        SetRow(name: "Support report",
               desc: "Versions, engine states, task counts, and a redacted settings dump — "
                   + "no URLs, file names, paths, or credentials. Nothing is ever sent automatically.") {
            HStack(spacing: 8) {
                Button("Copy") { copyDiagnostics() }
                Button("Export…") { exportDiagnostics() }
            }
        }
        Text("Withheld from every report: \(DiagnosticsRedaction.withheldSettingsKeys.sorted().joined(separator: ", ")).")
            .scaledFont(size: 10)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func makeDiagnostics() -> DiagnosticsBundle {
        // `DiagnosticsBundle` cannot see the engines — they are owned above GoelCore — so the caller
        // says. The view model reports its live engine set, keeping idle distinguishable from absent.
        DiagnosticsBundle.make(settings: vm.settings,
                               tasks: vm.tasks,
                               runningEngineKinds: vm.runningEngineKinds)
    }

    private func copyDiagnostics() {
        vm.copyToPasteboard(makeDiagnostics().plainText)
        vm.toastNow("Diagnostics copied — paste it into your bug report")
    }

    private func exportDiagnostics() {
        guard let url = FilePicker.save(name: "Goel-diagnostics.json", type: .json) else { return }
        do {
            try makeDiagnostics().jsonData().write(to: url, options: .atomic)
            vm.toastNow("Diagnostics saved")
        } catch {
            vm.settingsMessage("Export Failed",
                               "Couldn’t write the diagnostics report to that location.")
        }
    }

    // MARK: Antivirus

    private var antivirusPane: some View {
        PaneScaffold(title: "Antivirus", subtitle: "Run an external scanner on finished files. Optional, low priority on macOS.") {
            SetRow(name: "Scan finished files", desc: "") { SettingSwitch(isOn: binding(\.antivirusEnabled)) }
            SetRow(name: "Scanner", desc: "") {
                Dropdown(selection: binding(\.antivirusScanner), items: [
                    .option("", "Configure manually…"),
                    .option("ClamAV", "ClamAV"),
                ], width: 170)
            }
            SetRow(name: "Executable path", desc: "") {
                SettingText(text: binding(\.antivirusExecutablePath), width: 180)
            }
            SetRow(name: "Argument template", desc: "%path% is replaced with the file.") {
                SettingText(text: binding(\.antivirusArgumentTemplate), width: 120)
            }
        }
    }
}

// The reusable pane building blocks (PaneScaffold, SectionHeader, SetRow) and the bound controls
// (SettingSwitch/Text/Int/Double) live in `SettingsControls.swift`.
