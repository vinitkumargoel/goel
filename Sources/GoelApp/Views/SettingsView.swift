import SwiftUI
import AppKit
import GoelCore

/// The Preferences window, mirroring the brief's panels. General / Network /
/// Traffic Limits / BitTorrent / Advanced / Antivirus are functional panes;
/// Browser & Remote Access are shown as reserved/deferred placeholders.
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

        var deferred: Bool { self == .browser || self == .remote }
    }

    @State private var selection: Pane = .general

    var body: some View {
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $selection) { pane in
                Label {
                    HStack {
                        Text(pane.rawValue)
                        if pane.deferred {
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
                .opacity(pane.deferred ? 0.6 : 1)
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
            SetRow(name: "Default download folder",
                   desc: vm.settings.defaultSaveDirectory) {
                Button("Choose…") { chooseDefaultFolder() }
            }
            SetRow(name: "Launch at login", desc: "Start GoelDownloader when you log in.") {
                LocalToggle(initial: true)
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
                LocalPicker(options: ["None", "System", "HTTP", "SOCKS5"])
            }
            SetRow(name: "Connection timeout", desc: "Seconds before a stalled connection drops.") {
                LocalNumberField(initial: "30")
            }
            SetRow(name: "Retry count", desc: "Attempts before marking a download failed.") {
                LocalNumberField(initial: "5")
            }
            SetRow(name: "Custom user-agent", desc: "Sent with HTTP requests.") {
                LocalNumberField(initial: "GoelDownloader/1.0", width: 160)
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
            SectionHeader("Active: \(active.name) profile")
            SetRow(name: "Max download speed", desc: "0 = unlimited.") {
                Text(active.isDownloadUnlimited ? "Unlimited" : active.maxDownloadBytesPerSec.byteString + "/s")
                    .foregroundStyle(.secondary)
            }
            SetRow(name: "Max upload speed", desc: "") {
                Text(active.maxUploadBytesPerSec.byteString + "/s").foregroundStyle(.secondary)
            }
            SetRow(name: "Max connections (global)", desc: "") {
                Text("\(active.maxConnections)").foregroundStyle(.secondary)
            }
            SetRow(name: "Max connections per server", desc: "") {
                Text("\(active.maxConnectionsPerServer)").foregroundStyle(.secondary)
            }
            SetRow(name: "Max simultaneous downloads", desc: "") {
                Text("\(active.maxSimultaneousDownloads)").foregroundStyle(.secondary)
            }
            SetRow(name: "Stop seeding at ratio", desc: "") {
                Text(String(format: "%.1f", active.seedRatioLimit)).foregroundStyle(.secondary)
            }
            SetRow(name: "Max metadata-resolution downloads", desc: "Concurrent “requesting info” magnets.") {
                Text("\(active.maxMetadataResolutions)").foregroundStyle(.secondary)
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
            SetRow(name: "Default torrent client", desc: "Own magnet: links and .torrent files.") { LocalToggle(initial: true) }
            SetRow(name: "Auto-delete .torrent when done", desc: "Remove the source file after completion.") { LocalToggle(initial: true) }
            SetRow(name: "Watch folder for .torrent files", desc: "Auto-add new torrents that appear in a folder.") { LocalToggle(initial: false) }
            SetRow(name: "Encryption mode", desc: "Protocol encryption for peer connections.") {
                LocalPicker(options: ["Prefer", "Require", "Disable"])
            }
            SetRow(name: "Enable DHT", desc: "Find peers without a tracker.") { LocalToggle(initial: true) }
            SetRow(name: "Enable PeX", desc: "Exchange peers with other clients.") { LocalToggle(initial: true) }
            SetRow(name: "Enable µTP", desc: "BitTorrent over UDP for better congestion control.") { LocalToggle(initial: true) }
        }
    }

    // MARK: Advanced

    private var advancedPane: some View {
        PaneScaffold(title: "Advanced", subtitle: "Notifications, power management, and backup.") {
            SectionHeader("Notifications")
            SetRow(name: "On download added", desc: "") { LocalToggle(initial: true) }
            SetRow(name: "On download completed", desc: "") { LocalToggle(initial: true) }
            SetRow(name: "On download failed", desc: "") { LocalToggle(initial: true) }
            SectionHeader("Power management")
            SetRow(name: "Prevent sleep during active downloads", desc: "") { LocalToggle(initial: true) }
            SetRow(name: "Don't seed on battery", desc: "") { LocalToggle(initial: true) }
            SectionHeader("Backup")
            SetRow(name: "Periodically back up the download list", desc: "") { LocalToggle(initial: true) }
        }
    }

    // MARK: Antivirus

    private var antivirusPane: some View {
        PaneScaffold(title: "Antivirus", subtitle: "Run an external scanner on finished files. Optional, low priority on macOS.") {
            SetRow(name: "Scan finished files", desc: "") { LocalToggle(initial: false) }
            SetRow(name: "Scanner", desc: "") { LocalPicker(options: ["Configure manually…", "ClamAV"]) }
            SetRow(name: "Executable path", desc: "") { LocalNumberField(initial: "/usr/local/bin/clamscan", width: 180) }
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

private struct LocalToggle: View {
    @State var on: Bool
    init(initial: Bool) { _on = State(initialValue: initial) }
    var body: some View { Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch) }
}

private struct LocalPicker: View {
    let options: [String]
    @State private var selection: String
    init(options: [String]) { self.options = options; _selection = State(initialValue: options.first ?? "") }
    var body: some View {
        Picker("", selection: $selection) { ForEach(options, id: \.self) { Text($0).tag($0) } }
            .labelsHidden()
            .frame(width: 140)
    }
}

private struct LocalNumberField: View {
    @State private var text: String
    var width: CGFloat = 80
    init(initial: String, width: CGFloat = 80) { _text = State(initialValue: initial); self.width = width }
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: width)
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
