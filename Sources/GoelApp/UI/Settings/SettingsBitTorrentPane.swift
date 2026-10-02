import SwiftUI
import GoelCore

/// BitTorrent: protocol, privacy, and watch-folder behaviour, plus the extra-trackers list.
struct BitTorrentSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("BitTorrent"), subtitle: L10n.t("Protocol, privacy, and watch-folder behavior.")) {
            clientCard
            protocolCard
                .settingsColumn(.trailing)
            ExtraTrackersSettings()
        }
    }

    private var clientCard: some View {
        SettingsCard(title: L10n.t("Torrent files"), symbol: "doc.badge.arrow.up") {
            SettingRow(L10n.t("Default torrent client"), detail: L10n.t("Own magnet: links and .torrent files."),
                       isOn: setting(vm, \.btMakeDefaultClient))
            SettingRow(L10n.t("Auto-delete .torrent when done"), detail: L10n.t("Remove the source file after completion."),
                       isOn: setting(vm, \.btAutoDeleteTorrent))
            SettingRow(L10n.t("Watch folder for .torrent files"), detail: L10n.t("Auto-add new torrents that appear in a folder."),
                       isOn: setting(vm, \.btWatchFolderEnabled))
            // The watch is armed by `btWatchFolderPath`, not the switch above, and this chooser is its only writer.
            if vm.settings.btWatchFolderEnabled {
                SettingRow(L10n.t("Watched folder"),
                           detail: vm.settings.btWatchFolderPath.isEmpty
                               ? L10n.t("No folder chosen — nothing is being watched.")
                               : (vm.settings.btWatchFolderPath as NSString).abbreviatingWithTildeInPath,
                           isIndented: true) {
                    Button(L10n.t("Choose…"), systemImage: "folder") {
                        if let url = FilePicker.chooseDirectory() {
                            let path = url.path
                            vm.update { $0.btWatchFolderPath = path }
                        }
                    }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .accessibilityLabel(L10n.t("Choose watched torrent folder"))
                }
                SettingRow(L10n.t("Start watched torrents without confirmation"),
                           detail: L10n.t("Otherwise each new torrent waits for you to review its files."),
                           isIndented: true, isOn: setting(vm, \.btWatchStartWithoutConfirmation))
            }
        }
    }

    private var protocolCard: some View {
        SettingsCard(title: L10n.t("Peers & privacy"), symbol: "person.2") {
            SettingRow(L10n.t("Encryption mode"), detail: L10n.t("Protocol encryption for peer connections.")) {
                SettingsSelect(selection: setting(vm, \.btEncryptionMode), options: [
                    SettingsOption("prefer", L10n.t("Prefer")),
                    SettingsOption("require", L10n.t("Require")),
                    SettingsOption("disable", L10n.t("Disable")),
                ], width: 120)
            }
            SettingRow(L10n.t("Enable DHT"), detail: L10n.t("Find peers without a tracker."),
                       isOn: setting(vm, \.btEnableDHT))
            SettingRow(L10n.t("Enable PeX"), detail: L10n.t("Exchange peers with other clients."),
                       isOn: setting(vm, \.btEnablePeX))
            SettingRow(L10n.t("Enable Local Peer Discovery"), detail: L10n.t("Find peers on the local network."),
                       isOn: setting(vm, \.btEnableLPD))
            SettingRow(L10n.t("Enable µTP"), detail: L10n.t("BitTorrent over UDP for better congestion control."),
                       isOn: setting(vm, \.btEnableUTP))
            if let gap = swarmProxyGap {
                SettingsCardBlock {
                    StudioNote(tone: .warn, symbol: "exclamationmark.shield.fill", message: L10n.t(gap.rawValue))
                }
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
}

/// "Append trackers from a list · refresh daily". Public torrents only — the engine never adds
/// trackers to a private torrent.
struct ExtraTrackersSettings: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var urlDraft = ""

    var body: some View {
        SettingsCard(title: L10n.t("Extra trackers"), symbol: "antenna.radiowaves.left.and.right") {
            SettingRow(L10n.t("Append trackers from a list"),
                       detail: L10n.t("Adds public trackers to every new public torrent. The list refreshes daily."),
                       isOn: setting(vm, \.extraTrackersEnabled))
            if vm.settings.extraTrackersEnabled {
                SettingRow(L10n.t("Tracker list URL"), detail: statusText, isIndented: true) {
                    EmptyView()
                }
                SettingsCardBlock(showsDivider: false, verticalPadding: 0) {
                    HStack(spacing: Studio.Space.xs) {
                        SettingsTextField(text: $urlDraft, width: nil, placeholder: L10n.t("https://…/trackers.txt"),
                                          isMonospaced: true, accessibilityName: L10n.t("Tracker list URL"))
                            .onSubmit(commit)
                        Button(L10n.t("Refresh Now"), systemImage: "arrow.clockwise") {
                            vm.refreshTrackerList(from: urlDraft)
                        }
                        .buttonStyle(.studio(.secondary, size: .small))
                        .disabled(urlDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if Self.isPlainHTTP(urlDraft) {
                        StudioNote(tone: .warn, symbol: "exclamationmark.triangle.fill",
                                   message: L10n.t("This list is fetched over plain http — anyone on the network path can change which trackers your torrents announce to. Use https if the site offers it."))
                    }
                }
                .padding(.bottom, Studio.Space.m)
            }
        }
        // Typing never writes settings until Return or Refresh Now.
        .onAppear { urlDraft = vm.settings.extraTrackersURL }
    }

    private var statusText: String {
        let count = vm.settings.extraTrackers.count
        guard let when = vm.settings.extraTrackersUpdatedAt else {
            return L10n.t("Not fetched yet.")
        }
        let relative = when.formatted(.relative(presentation: .named))
        return L10n.t("%1$d trackers · updated %2$@", count, relative)
    }

    static func isPlainHTTP(_ raw: String) -> Bool {
        URL(string: raw.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased() == "http"
    }

    private func commit() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != vm.settings.extraTrackersURL else { return }
        vm.update { $0.extraTrackersURL = trimmed }
    }
}
