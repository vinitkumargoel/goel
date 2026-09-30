import SwiftUI
import GoelCore

struct DetailBottomPanel: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        Group {
            if let task = vm.selectedTask {
                content(for: task)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    /// Below about 900 pt the telemetry zone goes first, so the tabs keep room for their labels.
    private func content(for task: DownloadTask) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                summaryZone(for: task).frame(width: 280)
                Divider()
                telemetryZone(for: task).frame(width: 250)
                Divider()
                detailZone(for: task).frame(minWidth: Self.detailMinWidth, maxWidth: .infinity)
            }
            HStack(spacing: 0) {
                summaryZone(for: task).frame(width: 280)
                Divider()
                detailZone(for: task).frame(maxWidth: .infinity)
            }
        }
    }

    private static let detailMinWidth: CGFloat = 370

    private func downSamples(for task: DownloadTask, cap: Int = 60) -> [Double] {
        let pts = telemetry.taskHistory(task.id).map(\.down)
        return pts.count > cap ? Array(pts.suffix(cap)) : pts
    }

    private func summaryZone(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                FileTypeIcon(type: task.fileType, size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    DetailTitle(name: task.name)
                    HStack(spacing: 7) {
                        KindBadge(task: task)
                        DetailStatusPill(task: task)
                    }
                    .a11yGroup(label: A11y.sentence(task.accessibilityKindName,
                                                    task.accessibilityStatusName))
                }
                Spacer(minLength: 0)
            }

            MiniProgressBar(task: task, height: 6)

            if case .failed(let error) = task.status {
                FailureCard(task: task, error: error, vm: vm, compact: true)
            }

            Spacer(minLength: 0)

            DetailActionButtons(task: task, vm: vm)
        }
        .padding(16)
    }

    private func telemetryZone(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("LIVE THROUGHPUT"))
                .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.t("Live throughput"))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 12) {
                ThroughputGraph(samples: downSamples(for: task))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    DetailSpeedStat(symbol: "arrow.down",
                                    speed: telemetry.displaySpeed(for: task).down,
                                    color: Theme.green, size: 16)
                    Text(L10n.t("last 60s")).scaledFont(size: Theme.TextSize.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
            }

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 16) {
                telStat(L10n.t("Up")) {
                    DetailSpeedStat(symbol: "arrow.up", speed: telemetry.displaySpeed(for: task).up, color: Theme.teal, size: 12)
                }
                telStat(L10n.t("ETA")) {
                    Text(task.etaText ?? "—")
                        .scaledFont(size: Theme.TextSize.body, weight: .semibold, monospacedDigit: true)
                }
                telStat(task.swarmSummary.label) {
                    Text(task.swarmSummary.value)
                        .scaledFont(size: Theme.TextSize.body, weight: .semibold, monospacedDigit: true)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
    }

    private func telStat<Content: View>(_ label: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .accessibilityLabel(label)
            content()
        }
        .accessibilityElement(children: .combine)
    }

    private func detailZone(for task: DownloadTask) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                DetailTabPicker(selection: $vm.detailTab, segmentedMinWidth: 300, segmentedMaxWidth: 440)
                Spacer(minLength: 8)
                PanelDockToggle()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()

            ScrollView {
                tabBody(for: task)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func tabBody(for task: DownloadTask) -> some View {
        switch vm.detailTab {
        case .general:
            generalFacts(for: task).frame(maxWidth: 620, alignment: .leading)
        case .details:
            DetailsTab(task: task).frame(maxWidth: 620, alignment: .leading)
        case .progress:
            ProgressTab(task: task)
        case .files:
            FilesTab(task: task)
        case .connections:
            ConnectionsTab(task: task)
        }
    }

    private func generalFacts(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("\(task.percentComplete)%")
                    .scaledFont(size: 22, weight: .bold, monospacedDigit: true)
                Spacer()
                Text(task.sizeProgressText)
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)
            .a11yGroup(label: L10n.t("Progress"), value: task.accessibilityProgressValue)

            if task.kind == .torrent {
                KVRow(key: L10n.t("Uploaded"), value: task.bytesUploaded.byteString)
                KVRow(key: L10n.t("Share ratio"), value: String(format: "%.2f", task.shareRatio))
            }
            KVRow(key: L10n.t("Priority"), value: task.priority.title)
            KVRow(key: L10n.t("Added"), value: task.addedString)
            KVRow(key: L10n.t("Save path"), value: task.savePath, copyable: true)
            KVRow(key: L10n.t("Source"), value: task.sourceLocator, copyable: true)

            TaskSpeedGraph(taskID: task.id)
                .padding(.top, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                PanelDockToggle()
            }
            .padding(12)
            Spacer(minLength: 0)
            EmptyStateView(systemImage: "doc.text.magnifyingglass",
                           title: L10n.t("No selection"),
                           subtitle: L10n.t("Select a download to see its details, progress, and live throughput."),
                           symbolSize: 30)
            Spacer(minLength: 0)
        }
    }
}

struct PanelDockToggle: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let docksRight = vm.detailPanelPosition == .right
        IconButton(symbol: docksRight ? "rectangle.bottomhalf.inset.filled" : "rectangle.trailinghalf.inset.filled",
                   help: docksRight ? L10n.t("Dock panel to bottom") : L10n.t("Dock panel to right"),
                   size: 13,
                   spokenLabel: docksRight
                       ? L10n.t("Dock detail panel to the bottom")
                       : L10n.t("Dock detail panel to the right")) {
            vm.toggleDetailPanelPosition()
        }
        .accessibilityValue(docksRight ? L10n.t("Currently docked right") : L10n.t("Currently docked bottom"))
    }
}
