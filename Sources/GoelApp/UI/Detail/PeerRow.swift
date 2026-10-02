import SwiftUI
import GoelCore

/// Column widths shared by a table's header and rows, so the numbers line up.
private enum DetailTableColumn {
    static let percent: CGFloat = 38
    static let speed: CGFloat = 62
    static let adapter: CGFloat = 44
}

/// The torrent's peers (`.tbl`): address and client, how much each has, ↓, ↑ and the adapter.
struct DetailPeerTable: View {
    let task: DownloadTask

    var body: some View {
        let live = task.connections ?? []
        let seeds = task.seedCount.map { " · " + L10n.t("%d seeds", $0) } ?? ""
        DetailSection(L10n.t("Peers"), detail: L10n.t("%d peers", task.connectionCount) + seeds) {
            if live.isEmpty {
                DetailEmptyLine(text: L10n.t("No active peers"))
            } else {
                VStack(spacing: 0) {
                    DetailTableHeader {
                        Text(L10n.t("Peer · client")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L10n.t("Has")).frame(width: DetailTableColumn.percent, alignment: .trailing)
                        Text(verbatim: "↓").frame(width: DetailTableColumn.speed, alignment: .trailing)
                        Text(verbatim: "↑").frame(width: DetailTableColumn.speed, alignment: .trailing)
                        Text(L10n.t("Adapter")).frame(width: DetailTableColumn.adapter, alignment: .trailing)
                    }
                    ForEach(live) { peer in
                        PeerRow(peer: peer)
                    }
                }
            }
        }
    }
}

/// One peer: address, client, how much of the torrent it has, its rates and the adapter it rides.
struct PeerRow: View {
    let peer: TaskConnection

    private var client: String? { DetailNetworkText.peerClient(peer) }
    private var percent: String { DetailNetworkText.percent(peer.progress) }

    var body: some View {
        DetailTableRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.label)
                    .studioFont(.monoSmall)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(client ?? L10n.t("Unknown client"))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(percent)
                .studioFont(.monoSmall)
                .foregroundStyle(peer.progress >= 1 ? Studio.Palette.good : Studio.Palette.ink2)
                .frame(width: DetailTableColumn.percent, alignment: .trailing)
            DetailTableSpeed(speed: peer.downloadSpeed, tone: Studio.Palette.accent)
            DetailTableSpeed(speed: peer.uploadSpeed, tone: Studio.Palette.upload)
            Text(peer.adapterLabel ?? "—")
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink2)
                .lineLimit(1)
                .frame(width: DetailTableColumn.adapter, alignment: .trailing)
                .help(L10n.t("Network adapter"))
        }
        .a11yGroup(
            label: A11y.sentence(peer.label, client, peer.adapterLabel),
            value: A11y.sentence(L10n.t("Has %@", percent), A11y.speed(peer.downloadSpeed)))
    }
}

/// An HTTP download's live connections: segment, how far it is, its rate and the adapter.
struct DetailHTTPConnectionTable: View {
    let task: DownloadTask

    var body: some View {
        let live = task.connections ?? []
        let host = URLComponents(string: task.sourceLocator)?.host ?? ""
        DetailSection(L10n.t("HTTP connections"), detail: host.isEmpty ? nil : host) {
            if live.isEmpty {
                DetailEmptyLine(text: L10n.t("No active connections"))
            } else {
                VStack(spacing: 0) {
                    DetailTableHeader {
                        Text(L10n.t("Segment")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L10n.t("Done")).frame(width: DetailTableColumn.percent, alignment: .trailing)
                        Text(verbatim: "↓").frame(width: DetailTableColumn.speed, alignment: .trailing)
                        Text(L10n.t("Adapter")).frame(width: DetailTableColumn.adapter, alignment: .trailing)
                    }
                    ForEach(live) { segment in
                        row(segment)
                    }
                }
            }
        }
    }

    private func row(_ segment: TaskConnection) -> some View {
        let label = DetailNetworkText.segmentLabel(segment)
        let subtitle = segment.adapterId.flatMap { $0.isEmpty || $0 == "peer" ? nil : $0 }
        let percent = DetailNetworkText.percent(segment.progress)
        return DetailTableRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .studioFont(.monoSmall)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).studioFont(.caption).foregroundStyle(Studio.Palette.ink3).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(percent)
                .studioFont(.monoSmall)
                .foregroundStyle(segment.progress >= 1 ? Studio.Palette.good : Studio.Palette.ink2)
                .frame(width: DetailTableColumn.percent, alignment: .trailing)
            DetailTableSpeed(speed: segment.downloadSpeed, tone: Studio.Palette.accent)
            Text(segment.adapterLabel ?? "—")
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink2)
                .lineLimit(1)
                .frame(width: DetailTableColumn.adapter, alignment: .trailing)
        }
        .a11yGroup(label: A11y.sentence(label, segment.adapterLabel, subtitle),
                   value: A11y.sentence(A11y.speed(segment.downloadSpeed), percent))
    }
}

/// A table's header row: small tertiary labels over a hairline.
struct DetailTableHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Studio.Space.s) { content() }
                .studioFont(.caption.size(11).weight(650))
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
                .padding(.horizontal, Studio.Space.xxs)
                .padding(.bottom, Studio.Space.xs)
            StudioDivider()
        }
        .a11yDecorative()
    }
}

/// A table's body row, hairline beneath.
struct DetailTableRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Studio.Space.s) { content() }
                .padding(.horizontal, Studio.Space.xxs)
                .padding(.vertical, Studio.Space.cozy)
            StudioDivider()
        }
    }
}

/// A rate cell: the value in its tone, a faint "—" when idle.
private struct DetailTableSpeed: View {
    let speed: Double
    let tone: Color

    var body: some View {
        Text(speed > 0 ? speed.speedString : "—")
            .studioFont(.monoSmall)
            .foregroundStyle(speed > 0 ? tone : Studio.Palette.ink3)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: DetailTableColumn.speed, alignment: .trailing)
    }
}
