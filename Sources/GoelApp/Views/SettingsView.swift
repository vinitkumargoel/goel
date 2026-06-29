import SwiftUI
import AppKit
import GoelCore

/// The Preferences window, mirroring the brief's panels. General / Network /
/// Traffic Limits / BitTorrent / Advanced are fully functional panes whose
/// controls read from and write back to `vm.settings` (and through it the core),
/// so every choice persists across relaunch. Antivirus also persists its config
/// but carries a "soon" badge because the external-scanner step ships later.
/// Browser & Remote Access remain reserved/deferred placeholders.
struct SettingsView: View {
    @EnvironmentObject private var vm: AppViewModel

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case network = "Network"
        case traffic = "Traffic Limits"
        case bittorrent = "BitTorrent"
        case advanced = "Advanced"
        case antivirus = "Antivirus"
        case browser = "Browser"
        case remote = "Remote Access"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .network: return "globe"
            case .traffic: return "speedometer"
            case .bittorrent: return "circle.grid.cross"
            case .advanced: return "wand.and.stars"
            case .antivirus: return "shield"
            case .browser: return "safari"
            case .remote: return "display"
            }
        }

        /// Panes that carry the dimmed "soon" badge in the sidebar. Browser &
        /// Remote are placeholders; Antivirus persists its settings but its scan
        /// step is still on the roadmap, matching the intended design.
        var comingSoon: Bool { self == .browser || self == .remote || self == .antivirus }

        /// Panes that render the placeholder scaffold instead of live controls.
        var deferred: Bool { self == .browser || self == .remote }
    }

    @State private var selection: Pane = .general

    var body: some View {
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $selection) { pane in
                Label {
                    HStack {
                        Text(pane.rawValue)
                        if pane.comingSoon {
                            Spacer()
                            Text("soon")
                                .font(.system(size: 9))
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
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selection {
        case .general: generalPane
        case .network: networkPane
        case .traffic: trafficPane
        case .bittorrent: bittorrentPane
        case .advanced: advancedPane
        case .antivirus: antivirusPane
        case .browser: DeferredPane(title: "Browser Integration",
                                     desc: "A capture extension that hands downloads from your browser to GoelDownloader.",
                                     phase: "Phase 4")
        case .remote: DeferredPane(title: "Remote Access",
                                   desc: "Connect to a remote instance and control it from a web UI.",
                                   phase: "Phase 4")
        }
    }

    // MARK: Settings bindings

    /// A two-way binding into an `AppSettings` field that commits through
    /// ``AppViewModel/update(_:)`` so every edit persists and reaches the core.
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { vm.settings[keyPath: keyPath] },
            set: { newValue in vm.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// A binding into a field of the *currently selected* traffic profile. Edits
    /// write back into `settings.profiles` so the active profile's limits are
    /// editable (not read-only) and re-applied to the engines.
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

    /// A megabytes-per-second view onto a profile's byte/sec field, so speeds are
    /// edited in MB/s while the core keeps storing raw bytes (1 MB = 1024×1024).
    private func megabytesBinding(_ keyPath: WritableKeyPath<TrafficProfile, Int64>) -> Binding<Double> {
        Binding(
            get: { Double(vm.settings.selectedProfile[keyPath: keyPath]) / 1_048_576 },
            set: { mbPerSec in
                let bytes = Int64(max(0, mbPerSec) * 1_048_576)
                vm.update { settings in
                    guard let idx = settings.profiles.firstIndex(where: { $0.name == settings.selectedProfileName }) else { return }
                    settings.profiles[idx][keyPath: keyPath] = bytes
                }
            }
        )
    }

    // MARK: General

    private var generalPane: some View {
        PaneScaffold(title: "General", subtitle: "Appearance, startup, and where files land.") {
            SetRow(name: "Theme", desc: "Match the system or force light/dark.") {
                Picker("", selection: $vm.theme) {
                    ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            SetRow(name: "Language", desc: "English to start; structured for localization.") {
                Picker("", selection: binding(\.language)) {
                    ForEach(["English", "Deutsch", "हिन्दी", "日本語"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            SetRow(name: "Launch at login", desc: "Start GoelDownloader when you log in.") {
                SettingSwitch(isOn: binding(\.launchAtLogin))
            }
            SetRow(name: "Launch minimized", desc: "Open to the menu bar instead of a window.") {
                SettingSwitch(isOn: binding(\.launchMinimized))
            }
            SetRow(name: "Default download folder",
                   desc: "Choose automatically, by type, by source URL, or fixed.") {
                Picker("", selection: binding(\.defaultFolderRule)) {
                    Text("Automatic").tag("automatic")
                    Text("By file type").tag("byType")
                    Text("By source URL").tag("bySource")
                    Text("Fixed folder…").tag("fixed")
                }
                .labelsHidden()
                .frame(width: 150)
            }
            // For the "Fixed folder" rule, surface the actual destination and a
            // chooser so the existing default-save-directory feature stays usable.
            if vm.settings.defaultFolderRule == "fixed" {
                SetRow(name: "Fixed folder", desc: vm.settings.defaultSaveDirectory) {
                    Button("Choose…") { chooseDefaultFolder() }
                }
            }
        }
    }

    private func chooseDefaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            vm.setDefaultSaveDirectory(url.path)
        }
    }

    // MARK: Network

    private var networkPane: some View {
        PaneScaffold(title: "Network", subtitle: "Proxy, timeouts, retries, and authentication.") {
            SetRow(name: "Proxy", desc: "Route traffic through a proxy server.") {
                Picker("", selection: binding(\.proxyMode)) {
                    Text("None").tag("none")
                    Text("System").tag("system")
                    Text("Manual").tag("manual")
                }
                .labelsHidden()
                .frame(width: 150)
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
            SetRow(name: "Custom user-agent", desc: "Sent with HTTP requests.") {
                SettingText(text: binding(\.userAgent), width: 160)
            }
            SetRow(name: "Cookie / auth handling", desc: "Reuse cookies for protected downloads.") {
                SettingSwitch(isOn: binding(\.cookieAuthEnabled))
            }
        }
    }

    // MARK: Traffic Limits

    private var trafficPane: some View {
        PaneScaffold(title: "Traffic Limits",
                     subtitle: "Three switchable profiles. The status-bar snail toggles Unlimited vs the active profile.") {
            HStack(spacing: 10) {
                ForEach(vm.settings.profiles) { profile in
                    profileCard(profile)
                }
            }
            .padding(.bottom, 8)

            let active = vm.settings.selectedProfile
            SectionHeader("Editing: \(active.name) profile")
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
                Text("↓ \(profile.isDownloadUnlimited ? "Unlimited" : profile.maxDownloadBytesPerSec.byteString + "/s")\n↑ \(profile.maxUploadBytesPerSec.byteString)/s\n\(profile.maxConnections) conns · \(profile.maxSimultaneousDownloads) active\nseed to \(String(format: "%.1f", profile.seedRatioLimit))×")
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
            SetRow(name: "Start watched torrents without confirmation", desc: "") {
                SettingSwitch(isOn: binding(\.btWatchStartWithoutConfirmation))
            }
            SetRow(name: "Encryption mode", desc: "Protocol encryption for peer connections.") {
                Picker("", selection: binding(\.btEncryptionMode)) {
                    Text("Prefer").tag("prefer")
                    Text("Require").tag("require")
                    Text("Disable").tag("disable")
                }
                .labelsHidden()
                .frame(width: 140)
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
        }
    }

    // MARK: Advanced

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
                    // Entering a positive threshold enables the pause-on-battery
                    // feature; entering 0 disables it. One control, both fields.
                    SettingInt(value: Binding(
                        get: { vm.settings.batteryThresholdPercent },
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
            SectionHeader("Backup")
            SetRow(name: "Periodically back up the download list", desc: "") { SettingSwitch(isOn: binding(\.backupEnabled)) }
            SetRow(name: "Backup interval", desc: "") {
                Picker("", selection: binding(\.backupIntervalHours)) {
                    Text("Hourly").tag(1)
                    Text("Daily").tag(24)
                    Text("Weekly").tag(168)
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }

    // MARK: Antivirus

    private var antivirusPane: some View {
        PaneScaffold(title: "Antivirus", subtitle: "Run an external scanner on finished files. Optional, low priority on macOS.") {
            SetRow(name: "Scan finished files", desc: "") { SettingSwitch(isOn: binding(\.antivirusEnabled)) }
            SetRow(name: "Scanner", desc: "") {
                Picker("", selection: binding(\.antivirusScanner)) {
                    Text("Configure manually…").tag("")
                    Text("ClamAV").tag("ClamAV")
                }
                .labelsHidden()
                .frame(width: 170)
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

// MARK: - Building blocks

private struct PaneScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 16)
            content
        }
    }
}

private struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

private struct SetRow<Control: View>: View {
    let name: String
    let desc: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13))
                if !desc.isEmpty {
                    Text(desc).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
            control
        }
        .padding(.vertical, 10)
        Divider()
    }
}

// MARK: - Bound controls

/// A switch backed by a real settings `Binding`, so its initial state reflects
/// the persisted value and toggling commits through ``AppViewModel/update(_:)``.
private struct SettingSwitch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch) }
}

/// A free-text field bound to a settings string.
private struct SettingText: View {
    @Binding var text: String
    var width: CGFloat = 80
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: width)
    }
}

/// A numeric field bound to a settings integer.
private struct SettingInt: View {
    @Binding var value: Int
    var width: CGFloat = 80
    var body: some View {
        TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: width)
    }
}

/// A numeric field bound to a settings double (timeouts, intervals, speeds, ratio).
private struct SettingDouble: View {
    @Binding var value: Double
    var width: CGFloat = 80
    var body: some View {
        TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: width)
    }
}

private struct DeferredPane: View {
    let title: String
    let desc: String
    let phase: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(desc).font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
            VStack(spacing: 10) {
                Text("🚧").font(.system(size: 34))
                Text("Reserved for \(phase)").font(.system(size: 14)).foregroundStyle(.secondary)
                Text("This panel is intentionally a placeholder.\nThe feature is acknowledged in the roadmap and ships later.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(30)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Theme.hairline))
            .padding(.top, 8)
        }
    }
}
