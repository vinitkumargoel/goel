import SwiftUI
import GoelCore

/// Network: for a torrent the swarm facts, piece order, the piece map, peers and trackers; for
/// everything else the server's answers, the parallel segments and the connections.
struct DetailNetworkTab: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.l) {
            if task.kind == .torrent {
                torrentFacts
                if task.status != .completed {
                    sequentialRow
                }
                if task.showsProgressDetail || task.status == .requestingMetadata {
                    DetailPieceMap(task: task)
                }
                DetailPeerTable(task: task)
                DetailTrackerSection(task: task)
            } else {
                httpFacts
                DetailSegmentBars(task: task)
                DetailHTTPConnectionTable(task: task)
            }
        }
    }

    private var torrentFacts: some View {
        DetailFacts {
            DetailFactRow(L10n.t("Info hash"), value: task.displayInfoHash ?? "—", mono: true,
                          copyable: task.displayInfoHash != nil)
            DetailFactRow(L10n.t("Peers"), value: L10n.t("%d connected", task.connectionCount))
            DetailFactRow(L10n.t("Seeds"), value: task.seedCount.map { L10n.t("%d available", $0) } ?? "—")
            DetailFactRow(L10n.t("Leechers"), value: "\(task.leecherCount)", mono: true)
            DetailFactRow(L10n.t("Protocol"), value: DetailNetworkText.torrentProtocol(vm.settings))
            DetailFactRow(L10n.t("Encryption"), value: DetailNetworkText.encryption(vm.settings))
            if let limit = task.seedRatioLimit, limit > 0 {
                DetailFactRow(L10n.t("Seed until ratio"), value: String(format: "%.1f", limit), tone: .upload)
            }
        }
    }

    /// Piece order as a switch (the list's context menu offers the same toggle).
    private var sequentialRow: some View {
        let isOn = task.sequentialDownload == true
        return HStack(spacing: Studio.Space.s) {
            (Text(L10n.t("Piece order")) + Text(verbatim: " · ") + Text(L10n.t("Sequential (streaming)")).bold())
                .studioFont(.small)
                .foregroundStyle(isOn ? Studio.Palette.ink : Studio.Palette.ink2)
            Spacer(minLength: Studio.Space.s)
            Toggle(isOn: Binding(get: { isOn }, set: { vm.setSequential($0, task: task.id) })) { EmptyView() }
                .toggleStyle(.studioSwitch)
                .accessibilityLabel(L10n.t("Sequential Download"))
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, Studio.Space.s)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
            .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
    }

    private var httpFacts: some View {
        let range = DetailNetworkText.range(task)
        let resumable = DetailNetworkText.resumable(task)
        let checksum = DetailNetworkText.checksum(task)
        return DetailFacts {
            DetailFactRow(L10n.t("URL"), value: task.sourceLocator, mono: true, copyable: true)
            DetailFactRow(L10n.t("MIME type"), value: task.remoteInfo?.mimeType ?? "—", mono: true)
            DetailFactRow(L10n.t("Server"), value: task.remoteInfo?.server ?? "—")
            DetailFactRow(L10n.t("Range support"), value: range.text, tone: range.tone)
            DetailFactRow(L10n.t("Segments"), value: L10n.t("%d connections", max(1, task.connectionCount)))
            DetailFactRow(L10n.t("Resumable"), value: resumable.text, tone: resumable.tone)
            DetailFactRow(L10n.t("ETag"), value: task.remoteInfo?.etag ?? "—", mono: true)
            DetailFactRow(key: L10n.t("Checksum"), spokenValue: checksum.text) {
                if let tone = checksum.tone {
                    StudioPill(checksum.text, tone: tone, showsDot: false)
                } else {
                    DetailFactText(text: checksum.text, tone: .neutral)
                }
            }
        }
    }
}
