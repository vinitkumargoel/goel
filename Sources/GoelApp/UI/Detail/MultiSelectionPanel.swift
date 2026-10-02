import SwiftUI
import GoelCore

/// The detail panel while several rows are selected: one combined arc, what is left, the first
/// few files, and the bulk commands the list's context menu offers (the same view-model calls).
/// In the bottom dock the parts sit in three zones on one row, so the actions stay above the fold.
struct MultiSelectionPanel: View {
    var horizontal = false

    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        let tasks = vm.selectedTasks
        let summary = SelectionAggregate(tasks: tasks) { telemetry.displaySpeed(for: $0) }
        let queue = QueueOverview(tasks: tasks) { telemetry.displaySpeed(for: $0) }
        if horizontal {
            bottomLayout(summary, queue: queue)
        } else {
            sideLayout(summary, queue: queue)
        }
    }

    // MARK: Side

    private func sideLayout(_ summary: SelectionAggregate, queue: QueueOverview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
                titles(summary)
                Spacer(minLength: Studio.Space.s)
                Button(L10n.t("Deselect")) { vm.selectNone() }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                HStack(spacing: 2) {
                    DetailDockToggle()
                    DetailCloseButton()
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            .padding(.horizontal, Studio.Space.l)
            .padding(.top, Studio.Space.l)
            .padding(.bottom, Studio.Space.m)
            ScrollView {
                VStack(alignment: .leading, spacing: Studio.Space.ml) {
                    hero(summary, queue: queue)
                    previewList(summary)
                    MultiSelectionActions(summary: summary, compact: false)
                }
                .padding(.horizontal, Studio.Space.l)
                .padding(.bottom, Studio.Space.l)
            }
        }
    }

    private func titles(_ summary: SelectionAggregate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
                .studioFont(horizontal ? .title3 : .title2)
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !summary.subtitle.isEmpty {
                Text(summary.subtitle)
                    .studioFont(.small)
                    .monospacedDigit()
                    .foregroundStyle(Studio.Palette.ink2)
            }
        }
    }

    private func hero(_ summary: SelectionAggregate, queue: QueueOverview) -> some View {
        HStack(spacing: Studio.Space.xl) {
            ring(summary, diameter: 104)
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                Text(L10n.t("combined")).studioFont(.small).foregroundStyle(Studio.Palette.ink2)
                if queue.remainingBytes > 0 {
                    Text(L10n.t("%@ left", queue.remainingBytes.byteString))
                        .studioFont(.title2.weight(700))
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                HStack(spacing: Studio.Space.sm) {
                    DetailSpeedText(direction: .down, speed: summary.speed.down)
                    DetailSpeedText(direction: .up, speed: summary.speed.up, showsIdle: false)
                }
                if let eta = etaText(queue) {
                    Text(eta).studioFont(.mono).foregroundStyle(Studio.Palette.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Studio.Space.l)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
            .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
    }

    private func ring(_ summary: SelectionAggregate, diameter: CGFloat) -> some View {
        StudioProgressArc(fraction: summary.fraction,
                          tone: summary.failedCount == summary.count ? .bad : .accent,
                          diameter: diameter, accessibilityLabel: L10n.t("Combined progress"))
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func previewList(_ summary: SelectionAggregate) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            ForEach(summary.preview) { task in
                HStack(spacing: Studio.Space.s) {
                    DetailTaskArtwork(task: task, size: .xs)
                    FileNameText(task.compactDisplayName, lineLimit: 1)
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.t("%d%%", task.percentComplete))
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink2)
                }
                .accessibilityElement(children: .combine)
            }
            if summary.count > summary.preview.count {
                Text(L10n.t("and %d more", summary.count - summary.preview.count))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .padding(.leading, 32)
            }
        }
    }

    private func etaText(_ queue: QueueOverview) -> String? {
        guard let eta = queue.eta else { return nil }
        return L10n.t("%@ left", DownloadTask.etaString(eta))
    }

    // MARK: Bottom dock

    private func bottomLayout(_ summary: SelectionAggregate, queue: QueueOverview) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            HStack(alignment: .center, spacing: Studio.Space.xl) {
                HStack(spacing: Studio.Space.m) {
                    tileStack(summary.preview)
                    titles(summary)
                }
                .frame(minWidth: 190, alignment: .leading)

                VStack(alignment: .leading, spacing: Studio.Space.xs) {
                    HStack(spacing: Studio.Space.s) {
                        Text(L10n.t("%d%% combined", Int((summary.fraction * 100).rounded())))
                            .studioFont(.bodyStrong)
                            .monospacedDigit()
                            .foregroundStyle(Studio.Palette.ink)
                        Spacer(minLength: Studio.Space.s)
                        DetailSpeedText(direction: .down, speed: summary.speed.down)
                        if let eta = etaText(queue) {
                            Text(eta).studioFont(.mono).foregroundStyle(Studio.Palette.ink2)
                        }
                    }
                    StudioLinearProgress(fraction: summary.fraction,
                                         tone: summary.failedCount == summary.count ? .bad : .accent,
                                         accessibilityLabel: L10n.t("Combined progress"))
                }
                .frame(minWidth: 140, maxWidth: .infinity)

                HStack(spacing: 2) {
                    DetailDockToggle()
                    DetailCloseButton()
                }
            }
            MultiSelectionActions(summary: summary, compact: true)
            Spacer(minLength: 0)
            DetailForcedDockNote()
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.vertical, Studio.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Up to three artwork tiles fanned out, the first on top.
    private func tileStack(_ tasks: [DownloadTask]) -> some View {
        ZStack {
            ForEach(Array(tasks.enumerated().reversed()), id: \.element.id) { index, task in
                DetailTaskArtwork(task: task, size: .m)
                    .rotationEffect(.degrees(Double(index) * 8))
                    .offset(x: CGFloat(index) * 10, y: CGFloat(index) * -3)
                    .background {
                        RoundedRectangle(cornerRadius: Studio.Radius.tile, style: .continuous)
                            .fill(Studio.Palette.card)
                            .studioElevation(.raised)
                            .rotationEffect(.degrees(Double(index) * 8))
                            .offset(x: CGFloat(index) * 10, y: CGFloat(index) * -3)
                    }
            }
        }
        .frame(width: 70, height: 50, alignment: .leading)
        .a11yDecorative()
    }
}
