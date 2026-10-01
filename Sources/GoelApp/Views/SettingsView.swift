import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

struct SettingsView: View {
    @EnvironmentObject private var vm: AppViewModel

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case rules = "Rules"
        case notifications = "Notifications"
        case network = "Network"
        case traffic = "Speed & Connections"
        case bittorrent = "BitTorrent"
        case scheduler = "Scheduler"
        case rss = "RSS Feeds"
        case aggregation = "Multi-path"
        case afterDownload = "Extract & Scripts"
        case antivirus = "Antivirus"
        case media = "Media Tools"
        case browser = "Browser"
        case remote = "Web Access"
        case backup = "Backup & Updates"
        case audit = "Audit Log"
        case diagnostics = "Diagnostics"
        case license = "Licence"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .rules: return "line.3.horizontal.decrease.circle"
            case .notifications: return "bell.badge"
            case .network: return "globe"
            case .aggregation: return "point.3.connected.trianglepath.dotted"
            case .traffic: return "speedometer"
            case .bittorrent: return "circle.grid.cross"
            case .scheduler: return "clock"
            case .rss: return "dot.radiowaves.up.forward"
            case .afterDownload: return "wand.and.stars"
            case .media: return "film"
            case .backup: return "externaldrive.badge.timemachine"
            case .diagnostics: return "stethoscope"
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
    @State private var searchText = ""
    /// What VoiceOver last heard about the results, so an unchanged result set isn't re-announced per keystroke.
    @State private var announcedResults: [Pane]?

    @ObservedObject private var route = SettingsRoute.shared

    private var matchingPanes: [Pane] { SettingsSearch.panes(matching: searchText) }

    var body: some View {
        let matches = matchingPanes
        HStack(spacing: 0) {
            sidebar(matches)
                .frame(width: 184)

            Divider()

            if matches.isEmpty {
                // The pane from before the search must not stay on screen as if it matched.
                noMatchContent
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        paneContent
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.settingsSearchQuery, searchText)
            }
        }
        // Follow the filter: a pane the search hides must not stay on screen as if it matched.
        .onChange(of: searchText) { _, query in
            let panes = matchingPanes
            if let first = panes.first, !panes.contains(selection) { selection = first }
            announceResults(panes, for: query)
        }
        // Clear the request once consumed, or asking for the same pane twice never fires onChange again.
        .onChange(of: route.requestedPane) { _, requested in
            guard let requested else { return }
            searchText = route.requestedHighlight ?? ""
            route.requestedHighlight = nil
            selection = requested
            route.requestedPane = nil
        }
        .onAppear {
            if let requested = route.requestedPane {
                searchText = route.requestedHighlight ?? ""
                route.requestedHighlight = nil
                selection = requested
                route.requestedPane = nil
            }
        }
        .overlay(alignment: .bottom) { ToastOverlay(queue: vm.toasts, bottomPadding: 24) }
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


    private var noMatchContent: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 28)
                .foregroundStyle(.secondary)
                .a11yDecorative()
            Text(L10n.t("No settings match"))
                .scaledFont(size: Theme.TextSize.title, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t("Try a different word, or clear the search to see every pane."))
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.t("Clear search")) { searchText = "" }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func announceResults(_ panes: [Pane], for query: String) {
        guard SettingsSearch.isActive(query) else {
            announcedResults = nil
            return
        }
        guard panes != announcedResults else { return }
        announcedResults = panes
        A11yAnnouncer.announce(SettingsSearch.resultAnnouncement(count: panes.count))
    }

    private func sidebar(_ matches: [Pane]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .a11yDecorative()
                TextField(L10n.t("Search settings"), text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L10n.t("Search settings"))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.t("Clear search"))
                    .a11yButton(L10n.t("Clear search"))
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .background(Theme.fillRest, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if matches.isEmpty {
                Text(L10n.t("No settings match “%@”.", searchText.trimmingCharacters(in: .whitespaces)))
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                List(selection: $selection) {
                    rowHits
                    ForEach(Pane.Group.allCases) { group in
                        let panes = group.panes.filter(matches.contains)
                        if !panes.isEmpty {
                            Section(group.title) {
                                ForEach(panes) { pane in
                                    sidebarRow(pane)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    /// Individual settings that match, each labelled with its pane: "sleep" finds the row, not
    /// just the three panes it could be on.
    @ViewBuilder
    private var rowHits: some View {
        let hits = SettingsSearch.rows(matching: searchText, limit: 8)
        if !hits.isEmpty {
            Section(L10n.t("Matching settings")) {
                ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                    rowHit(title: hit.title, pane: hit.pane)
                }
            }
        }
    }

    private func rowHit(title: String, pane: Pane) -> some View {
        Button { selection = pane } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(size: Theme.TextSize.body)
                    .lineLimit(2)
                Text(L10n.t(pane.rawValue))
                    .scaledFont(size: Theme.TextSize.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("%1$@, in %2$@", title, L10n.t(pane.rawValue)))
    }

    private func sidebarRow(_ pane: Pane) -> some View {
        Label {
            HStack {
                Text(L10n.t(pane.rawValue))
                if pane.comingSoon {
                    Spacer()
                    Text(L10n.t("soon"))
                        .scaledFont(size: 9)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.fillRest, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: pane.symbol)
        }
        .tag(pane)
        .opacity(pane.comingSoon ? 0.6 : 1)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selection {
        case .general: generalPane
        case .rules: RulesPane()
        case .notifications: NotificationsPane()
        case .network: networkPane
        case .aggregation: AggregationSettingsPane()
        case .traffic: trafficPane
        case .bittorrent: bittorrentPane
        case .scheduler: SchedulerPane()
        case .rss: RSSPane()
        case .afterDownload: AfterDownloadPane()
        case .media: MediaToolsPane()
        case .backup: BackupUpdatesPane()
        case .diagnostics: DiagnosticsPane()
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
        PaneScaffold(title: L10n.t("General"), subtitle: L10n.t("Appearance, startup, where files land, and sleep.")) {
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
            PowerSection()
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
                   desc: L10n.t("Periodically re-check finished HTTP downloads and fetch again if the server’s file changed.")) {
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
        PaneScaffold(title: L10n.t("Speed & Connections"),
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
                    Text(L10n.t("MB/s")).scaledFont(size: Theme.TextSize.body).foregroundStyle(.secondary)
                }
            }
            SetRow(name: L10n.t("Max upload speed"), desc: L10n.t("Seeding and peer uploads. 0 = unlimited.")) {
                HStack(spacing: 4) {
                    SettingDouble(value: megabytesBinding(\.maxUploadBytesPerSec), width: 70)
                    Text(L10n.t("MB/s")).scaledFont(size: Theme.TextSize.body).foregroundStyle(.secondary)
                }
            }
            SetRow(name: L10n.t("Max connections (global)"), desc: L10n.t("Open connections across every download.")) {
                SettingInt(value: profileBinding(\.maxConnections))
            }
            SetRow(name: L10n.t("Max connections per server"), desc: L10n.t("Some servers block clients that open too many.")) {
                SettingInt(value: profileBinding(\.maxConnectionsPerServer))
            }
            SetRow(name: L10n.t("Max simultaneous downloads"), desc: L10n.t("The rest wait in the queue.")) {
                SettingInt(value: profileBinding(\.maxSimultaneousDownloads))
            }
            SetRow(name: L10n.t("Stop seeding at ratio"), desc: L10n.t("Uploaded ÷ downloaded; 0 seeds forever.")) {
                SettingDouble(value: profileBinding(\.seedRatioLimit))
            }
            SetRow(name: L10n.t("Max metadata-resolution downloads"), desc: L10n.t("Concurrent “requesting info” magnets.")) {
                SettingInt(value: profileBinding(\.maxMetadataResolutions))
            }
            SetRow(name: L10n.t("Extra connections per download"),
                   desc: L10n.t("Split one file across more connections when the server allows it.")) {
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
                    Text(profile.name).scaledFont(size: Theme.TextSize.title, weight: .semibold)
                }
                Text("↓ \(profile.isDownloadUnlimited ? L10n.t("Unlimited") : profile.maxDownloadBytesPerSec.byteString + "/s")\n↑ \(profile.maxUploadBytesPerSec <= 0 ? L10n.t("Unlimited") : profile.maxUploadBytesPerSec.byteString + "/s")\n\(L10n.t("%1$@ conns · %2$@ active", String(profile.maxConnections), String(profile.maxSimultaneousDownloads)))\n\(L10n.t("seed to %@×", String(format: "%.1f", profile.seedRatioLimit)))")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(selected ? Theme.accent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
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
                SetRow(name: L10n.t("Start watched torrents without confirmation"),
                       desc: L10n.t("Otherwise each new torrent waits for you to review its files.")) {
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
            ExtraTrackersSettings()
            if let gap = swarmProxyGap {
                Label(L10n.t(gap.rawValue), systemImage: "exclamationmark.shield.fill")
                    .scaledFont(size: Theme.TextSize.meta)
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

    private var antivirusPane: some View {
        PaneScaffold(title: L10n.t("Antivirus"), subtitle: L10n.t("Run an external scanner on finished files. Optional, low priority on macOS.")) {
            SetRow(name: L10n.t("Scan finished files"), desc: L10n.t("Run the scanner on each file when it finishes.")) { SettingSwitch(isOn: binding(\.antivirusEnabled)) }
            SetRow(name: L10n.t("Scanner"), desc: L10n.t("Pick ClamAV for its defaults, or set the command yourself.")) {
                Dropdown(selection: binding(\.antivirusScanner), items: [
                    .option("", L10n.t("Configure manually…")),
                    .option("ClamAV", "ClamAV"),
                ], width: 170)
            }
            SetRow(name: L10n.t("Executable path"), desc: L10n.t("Full path to the scanner, e.g. /opt/homebrew/bin/clamscan.")) {
                SettingText(text: binding(\.antivirusExecutablePath), width: 180)
            }
            SetRow(name: L10n.t("Argument template"), desc: L10n.t("%path% is replaced with the file.")) {
                SettingText(text: binding(\.antivirusArgumentTemplate), width: 120)
            }
        }
    }
}
