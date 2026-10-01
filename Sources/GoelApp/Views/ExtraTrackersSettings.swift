import SwiftUI
import GoelCore

/// Settings › BitTorrent: "Append trackers from URL · refresh daily". Public torrents only —
/// the engine never adds trackers to a private torrent.
struct ExtraTrackersSettings: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var urlDraft = ""

    var body: some View {
        Group { rows }
            // Typing never writes settings until Return or Refresh Now.
            .onAppear { urlDraft = vm.settings.extraTrackersURL }
    }

    @ViewBuilder
    private var rows: some View {
        SetRow(name: L10n.t("Append trackers from a list"),
               desc: L10n.t("Adds public trackers to every new public torrent. The list refreshes daily.")) {
            SettingSwitch(isOn: setting(vm, \.extraTrackersEnabled))
        }
        if vm.settings.extraTrackersEnabled {
            SetRow(name: L10n.t("Tracker list URL"), desc: statusText) {
                HStack(spacing: 6) {
                    TextField(L10n.t("https://…/trackers.txt"), text: $urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(commit)
                        .accessibilityLabel(L10n.t("Tracker list URL"))
                    Button(L10n.t("Refresh Now")) { vm.refreshTrackerList(from: urlDraft) }
                        .disabled(urlDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if Self.isPlainHTTP(urlDraft) {
                Label(L10n.t("This list is fetched over plain http — anyone on the network path can change which trackers your torrents announce to. Use https if the site offers it."),
                      systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
