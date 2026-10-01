import SwiftUI
import GoelCore

/// One torrent peer: address, client, how much of the torrent it has, and the adapter it rides.
struct PeerRow: View {
    let peer: TaskConnection

    private var client: String? {
        let detail = peer.detail.trimmingCharacters(in: .whitespaces)
        return detail.isEmpty || detail == "peer" ? nil : detail
    }

    private var percent: String { "\(Int((peer.progress * 100).rounded()))%" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                identity
                Spacer(minLength: 6)
                Text(peer.downloadSpeed > 0 ? peer.downloadSpeed.speedString : "—")
                    .frame(width: 64, alignment: .trailing).foregroundStyle(Theme.green)
                Text(peer.uploadSpeed > 0 ? peer.uploadSpeed.speedString : "—")
                    .frame(width: 56, alignment: .trailing).foregroundStyle(Theme.teal)
            }
            .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
            .padding(.vertical, 6)
            Divider()
        }
        .a11yGroup(
            label: A11y.sentence(peer.label, client, peer.adapterLabel),
            value: A11y.sentence(L10n.t("Has %@", percent), A11y.speed(peer.downloadSpeed)))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(peer.label).lineLimit(1).truncationMode(.middle)
                if let adapter = peer.adapterLabel {
                    Text(adapter)
                        .scaledFont(size: Theme.TextSize.micro)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .help(L10n.t("Network adapter"))
                }
            }
            HStack(spacing: 6) {
                Text(client ?? L10n.t("Unknown client"))
                    .scaledFont(size: Theme.TextSize.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                ProgressView(value: min(1, max(0, peer.progress)))
                    .progressViewStyle(.linear).controlSize(.mini)
                    .frame(width: 60)
                    .tint(peer.progress >= 1 ? Theme.green : Theme.accent)
                Text(percent).scaledFont(size: Theme.TextSize.caption).foregroundStyle(.secondary)
            }
        }
    }
}
