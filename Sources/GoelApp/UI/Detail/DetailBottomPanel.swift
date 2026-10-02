import SwiftUI
import GoelCore

/// The inspector docked under the list: a summary zone, a live-throughput zone and the tabs,
/// side by side. It adapts down to about 560 pt: below ~920 pt the throughput zone goes first,
/// below ~650 pt the summary folds into a one-line strip above the tabs with icon actions. The
/// tab zone keeps its identity (and scroll position) across both thresholds.
struct DetailBottomPanel: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        Group {
            if vm.selectedTasks.count > 1 {
                MultiSelectionPanel(horizontal: true)
            } else if let task = vm.selectedTask {
                content(for: task)
            } else {
                QueueOverviewPanel(horizontal: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Studio.Palette.card)
        .foregroundStyle(Studio.Palette.ink)
    }

    private func content(for task: DownloadTask) -> some View {
        GeometryReader { proxy in
            let showsTelemetry = Self.fitsTelemetry(width: proxy.size.width)
            let showsSummary = Self.fitsSummary(width: proxy.size.width)
            HStack(spacing: 0) {
                if showsSummary {
                    summaryZone(for: task).frame(width: Self.summaryWidth)
                    zoneDivider
                }
                if showsTelemetry {
                    telemetryZone(for: task).frame(width: Self.telemetryWidth)
                    zoneDivider
                }
                VStack(spacing: 0) {
                    if !showsSummary {
                        compactSummary(for: task)
                    }
                    detailZone(for: task, compact: !showsSummary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var zoneDivider: some View {
        Rectangle().fill(Studio.Palette.hairline).frame(width: 1).accessibilityHidden(true)
    }

    static let summaryWidth: CGFloat = 290
    static let telemetryWidth: CGFloat = 260
    static let detailMinWidth: CGFloat = 370
    /// The narrowest the tab zone gets beside the summary before the summary folds away.
    static let detailNarrowWidth: CGFloat = 360

    /// Whether all three zones and their two dividers fit side by side.
    static func fitsTelemetry(width: CGFloat) -> Bool {
        width >= summaryWidth + telemetryWidth + detailMinWidth + 2
    }

    /// Whether the summary zone fits beside the tabs; narrower, it becomes a strip above them.
    static func fitsSummary(width: CGFloat) -> Bool {
        width >= summaryWidth + detailNarrowWidth + 1
    }

    /// The narrow dock's summary: artwork, name, badge and state, the icon actions, and a thin bar.
    private func compactSummary(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            HStack(spacing: Studio.Space.sm) {
                DetailTaskArtwork(task: task, size: .s)
                VStack(alignment: .leading, spacing: 3) {
                    FileNameText(task.compactDisplayName, lineLimit: 1)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: Studio.Space.xs) {
                        StudioKindBadge(kind: task.kind)
                        StudioStatusChip(state: StudioDownloadState(task: task), detail: DetailHeader.chipDetail(task))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(A11y.sentence(task.accessibilityKindName, task.accessibilityStatusName))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DetailIconActions(task: task)
            }
            StudioLinearProgress(fraction: task.status == .requestingMetadata ? nil : task.fractionCompleted,
                                 tone: StudioProgressTone(task: task), height: StudioLinearProgress.thinHeight)
                .accessibilityValue(task.accessibilityProgressValue)
            DetailForcedDockNote()
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.top, Studio.Space.m)
    }

    // MARK: Zones

    private func summaryZone(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            DetailHeader(task: task, artSize: .m, showsChrome: false)
            StudioLinearProgress(fraction: task.status == .requestingMetadata ? nil : task.fractionCompleted,
                                 tone: StudioProgressTone(task: task))
                .accessibilityValue(task.accessibilityProgressValue)
            if case .failed(let error) = task.status {
                FailureCard(task: task, error: error, compact: true)
            }
            Spacer(minLength: 0)
            DetailForcedDockNote()
            DetailActionButtons(task: task, fullWidth: false, completedVerbs: true, size: .small)
        }
        .padding(Studio.Space.l)
    }

    private func telemetryZone(for task: DownloadTask) -> some View {
        let speed = telemetry.displaySpeed(for: task)
        let history = Array(telemetry.taskHistory(task.id).suffix(60))
        return VStack(alignment: .leading, spacing: Studio.Space.sm) {
            StudioSectionHeader(L10n.t("Live throughput"), detail: L10n.t("last 60s"))
                .accessibilityLabel(L10n.t("Live throughput"))
            HStack(alignment: .lastTextBaseline, spacing: Studio.Space.s) {
                Text(speed.down >= 1 ? speed.down.speedString : "—")
                    .studioFont(.title1.size(26))
                    .foregroundStyle(speed.down >= 1 ? Studio.Palette.accent : Studio.Palette.ink3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(verbatim: "↓").studioFont(.mono).foregroundStyle(Studio.Palette.ink3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("Download %@", A11y.speed(speed.down)))
            if history.count > 1 {
                StudioSparkline(values: history.map(\.down), secondary: history.contains { $0.up >= 1 } ? history.map(\.up) : nil,
                                gridLines: 1, showsEndDot: true, accessibilityLabel: L10n.t("Recent throughput"))
                    .frame(height: 46)
                    .accessibilityValue(DetailThroughputChart.spokenSummary(history.map(\.down)))
            } else {
                Text(L10n.t("No samples yet"))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink3)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: Studio.Space.m) {
                telStat(L10n.t("Up")) {
                    DetailSpeedText(direction: .up, speed: speed.up, style: .monoBody.weight(600))
                }
                telStat(L10n.t("ETA")) {
                    Text(task.etaText ?? "—").studioFont(.monoBody.weight(600)).foregroundStyle(Studio.Palette.ink)
                }
                telStat(task.swarmSummary.label) {
                    Text(task.swarmSummary.value)
                        .studioFont(.monoBody.weight(600))
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)
            }
        }
        .padding(Studio.Space.l)
    }

    private func telStat<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityLabel(label)
            content()
        }
        .accessibilityElement(children: .combine)
    }

    private func detailZone(for task: DownloadTask, compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Studio.Space.sm) {
                DetailTabSwitcher(selection: $vm.detailTab, tabs: DetailTab.available(for: task))
                    .frame(maxWidth: 360)
                    .layoutPriority(1)
                Spacer(minLength: Studio.Space.s)
                if !compact {
                    HStack(spacing: 2) {
                        DetailDockToggle()
                        DetailCloseButton()
                    }
                }
            }
            .padding(.horizontal, Studio.Space.l)
            .padding(.top, compact ? Studio.Space.sm : Studio.Space.m)
            .padding(.bottom, Studio.Space.sm)

            ScrollView {
                tabBody(for: task, compact: compact)
                    .padding(.horizontal, Studio.Space.l)
                    .padding(.bottom, Studio.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func tabBody(for task: DownloadTask, compact: Bool) -> some View {
        switch vm.detailTab.resolved(for: task) {
        case .overview:
            VStack(alignment: .leading, spacing: Studio.Space.ml) {
                if compact, case .failed(let error) = task.status {
                    FailureCard(task: task, error: error, compact: true)
                }
                HStack(alignment: .lastTextBaseline) {
                    Text(L10n.t("%d%%", task.percentComplete))
                        .studioFont(.title1.size(24))
                        .foregroundStyle(Studio.Palette.ink)
                    Spacer()
                    Text(task.sizeProgressText).studioFont(.mono).foregroundStyle(Studio.Palette.ink2)
                }
                .a11yGroup(label: L10n.t("Progress"), value: task.accessibilityProgressValue)
                DetailOverviewFacts(task: task)
            }
            .frame(maxWidth: 620, alignment: .leading)
        case .files:
            DetailFilesTab(task: task)
        case .network:
            DetailNetworkTab(task: task).frame(maxWidth: 680, alignment: .leading)
        }
    }
}

/// The narrow dock's actions as icon buttons: the state's verb (filled), Folder and Copy.
private struct DetailIconActions: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let name = task.compactDisplayName
        HStack(spacing: Studio.Space.xxs) {
            if task.status.isActive {
                StudioIconButton("pause.fill", label: L10n.t("Pause %@", name), size: .small, isOn: true) { vm.pause(task.id) }
            } else if task.status == .paused || task.status == .queued {
                StudioIconButton("play.fill", label: L10n.t("Resume %@", name), size: .small, isOn: true) { vm.resume(task.id) }
            } else if task.status.isFailed {
                StudioIconButton("arrow.clockwise", label: L10n.t("Retry %@", name), size: .small, isOn: true) { vm.retry(task.id) }
            } else if task.isFileMissing {
                StudioIconButton("magnifyingglass", label: L10n.t("Locate %@", task.name), size: .small, isOn: true) {
                    vm.locateMissingFile(task)
                }
            } else if task.status == .completed {
                StudioIconButton("arrow.up.forward.app", label: L10n.t("Open %@", task.name), size: .small, isOn: true) {
                    vm.openFile(task)
                }
            }
            StudioIconButton("folder", label: L10n.t("Show %@ in Finder", name), size: .small, bordered: true) {
                vm.revealInFinder(task)
            }
            StudioIconButton("doc.on.doc", label: L10n.t("Copy source link for %@", name), size: .small, bordered: true) {
                vm.copyToPasteboard(task.sourceLocator)
            }
            DetailDockToggle()
            DetailCloseButton()
        }
    }
}
