import SwiftUI
import GoelCore

/// A torrent's piece map (`.pm`): one square per bucket, accent where the pieces are in,
/// warm while they arrive, the track colour where nothing is yet.
struct DetailPieceMap: View {
    let task: DownloadTask

    private static let columns = 24

    var body: some View {
        let buckets = task.pieceAvailability ?? []
        let counts = DetailPieceCounts(buckets)
        DetailSection(title: buckets.isEmpty
                          ? L10n.t("Piece map")
                          : L10n.t("Piece map · %1$@/%2$@ complete", String(counts.have), String(counts.total))) {
            EmptyView()
        } content: {
            if buckets.isEmpty {
                if task.status == .requestingMetadata {
                    HStack(spacing: Studio.Space.s) {
                        StudioProgressArc(fraction: nil, diameter: 14, lineWidth: 2) { EmptyView() }
                            .accessibilityHidden(true)
                        Text(L10n.t("Waiting for metadata…"))
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink3)
                    }
                    .padding(.vertical, Studio.Space.xxs)
                } else {
                    StudioLinearProgress(fraction: task.fractionCompleted, tone: StudioProgressTone(task: task),
                                         accessibilityLabel: L10n.t("Piece map"))
                }
            } else {
                grid(buckets)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.t("Piece map"))
                    .accessibilityValue(
                        L10n.t("%1$@ of %2$@ blocks complete, %3$@ in progress, %4$@ not started",
                               String(counts.have), String(counts.total), String(counts.partial),
                               String(counts.missing)))
                legend
            }
        }
    }

    private func grid(_ buckets: [Double]) -> some View {
        let columns = min(Self.columns, max(1, buckets.count))
        let rows = Int((Double(buckets.count) / Double(columns)).rounded(.up))
        let gap: CGFloat = 2
        return Canvas { context, size in
            let side = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            for (index, fraction) in buckets.enumerated() {
                let rect = CGRect(x: CGFloat(index % columns) * (side + gap),
                                  y: CGFloat(index / columns) * (side + gap),
                                  width: side, height: side)
                let cell = Path(roundedRect: rect, cornerRadius: min(2.5, side / 4))
                context.fill(cell, with: .color(Self.color(fraction)))
            }
        }
        .aspectRatio(CGFloat(columns) / CGFloat(max(1, rows)), contentMode: .fit)
    }

    static func color(_ fraction: Double) -> Color {
        if fraction >= 0.999 { return Studio.Palette.accent }
        if fraction > 0 { return Studio.Palette.warn.opacity(0.45 + 0.55 * fraction) }
        return Studio.Palette.track
    }

    private var legend: some View {
        HStack(spacing: Studio.Space.sm) {
            legendItem(Studio.Palette.accent, L10n.t("Have"))
            legendItem(Studio.Palette.warn, L10n.t("Downloading"))
            legendItem(Studio.Palette.track, L10n.t("Missing"))
        }
        .a11yDecorative()
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 9, height: 9)
            Text(label).studioFont(.caption).foregroundStyle(Studio.Palette.ink2)
        }
    }
}

/// An HTTP download's parallel segments as numbered bars, or the one overall bar when the
/// download runs on a single connection.
struct DetailSegmentBars: View {
    let task: DownloadTask

    var body: some View {
        let live = task.connections ?? []
        if live.isEmpty {
            DetailSection(L10n.t("Overall progress")) {
                HStack(spacing: Studio.Space.s) {
                    StudioLinearProgress(fraction: task.fractionCompleted,
                                         tone: task.status == .completed ? .good : StudioProgressTone(task: task))
                    Text(DetailNetworkText.percent(task.fractionCompleted))
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink2)
                        .frame(width: 40, alignment: .trailing)
                }
                .a11yGroup(label: L10n.t("Overall progress"), value: task.accessibilityProgressValue)
            }
        } else {
            DetailSection(L10n.t("%d parallel segments", live.count)) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(live.enumerated()), id: \.element.id) { index, segment in
                        row(index: index, segment: segment)
                    }
                }
            }
        }
    }

    private func row(index: Int, segment: TaskConnection) -> some View {
        let done = segment.progress >= 1
        return HStack(spacing: Studio.Space.s) {
            Text(verbatim: "\(index + 1)")
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink3)
                .frame(minWidth: 18, alignment: .leading)
            StudioLinearProgress(fraction: segment.progress, tone: done ? .good : .accent)
            Text(done ? L10n.t("done") : DetailNetworkText.percent(segment.progress))
                .studioFont(.monoSmall)
                .foregroundStyle(done ? Studio.Palette.good : Studio.Palette.ink2)
                .frame(width: 40, alignment: .trailing)
        }
        .a11yGroup(label: segment.label, value: A11y.percent(segment.progress))
    }
}
