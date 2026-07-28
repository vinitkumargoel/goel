import SwiftUI
import GoelCore

struct DetailBottomPanel: View {
    @EnvironmentObject private var vm: AppViewModel

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

    private func content(for task: DownloadTask) -> some View {
        HStack(spacing: 0) {
            summaryZone(for: task).frame(width: 280)
            Divider()
            telemetryZone(for: task).frame(width: 250)
            Divider()
            detailZone(for: task).frame(maxWidth: .infinity)
        }
    }

    private func downSamples(for task: DownloadTask, cap: Int = 60) -> [Double] {
        let pts = vm.taskSpeedHistory[task.id]?.map(\.down) ?? []
        return pts.count > cap ? Array(pts.suffix(cap)) : pts
    }

    private func summaryZone(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                FileTypeIcon(type: task.fileType, size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.name)
                        .scaledFont(size: 13.5, weight: .semibold)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
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
                Text(error.message)
                    .scaledFont(size: 11)
                    .foregroundStyle(Theme.red)
                    .lineLimit(2)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel(L10n.t("Download failed. %@", error.message))
            }

            Spacer(minLength: 0)

            DetailActionButtons(task: task, vm: vm)
        }
        .padding(16)
    }

    private func telemetryZone(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("LIVE THROUGHPUT"))
                .scaledFont(size: 10, weight: .bold)
                .tracking(0.7)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(L10n.t("Live throughput"))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 12) {
                ThroughputGraph(samples: downSamples(for: task))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    DetailSpeedStat(symbol: "arrow.down",
                                    speed: vm.displaySpeed(for: task).down,
                                    color: Theme.green, size: 16)
                    Text(L10n.t("last 60s")).scaledFont(size: 10).foregroundStyle(.tertiary)
                }
                .fixedSize()
            }

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 16) {
                telStat(L10n.t("Up")) {
                    DetailSpeedStat(symbol: "arrow.up", speed: vm.displaySpeed(for: task).up, color: Theme.teal, size: 12)
                }
                telStat(L10n.t("ETA")) {
                    Text(task.etaText ?? "—")
                        .scaledFont(size: 12.5, weight: .semibold, monospacedDigit: true)
                }
                telStat(task.swarmSummary.label) {
                    Text(task.swarmSummary.value)
                        .scaledFont(size: 12.5, weight: .semibold, monospacedDigit: true)
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
                .scaledFont(size: 10, weight: .bold)
                .tracking(0.7)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(label)
            content()
        }
        .accessibilityElement(children: .combine)
    }

    private func detailZone(for task: DownloadTask) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $vm.detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(L10n.t(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 440)
                .accessibilityLabel(L10n.t("Detail section"))
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
                    .scaledFont(size: 11.5)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)
            .a11yGroup(label: L10n.t("Progress"), value: task.accessibilityProgressValue)

            if task.kind == .torrent {
                KVRow(key: L10n.t("Uploaded"), value: task.bytesUploaded.byteString)
                KVRow(key: L10n.t("Share ratio"), value: String(format: "%.2f", task.shareRatio))
            }
            KVRow(key: L10n.t("Priority"), value: L10n.t(task.priority.displayName))
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
        Button {
            vm.toggleDetailPanelPosition()
        } label: {
            Image(systemName: vm.detailPanelPosition == .right
                  ? "rectangle.bottomhalf.inset.filled"
                  : "rectangle.trailinghalf.inset.filled")
                .scaledFont(size: 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(vm.detailPanelPosition == .right ? L10n.t("Dock panel to bottom") : L10n.t("Dock panel to right"))
        .a11yButton(vm.detailPanelPosition == .right
                    ? L10n.t("Dock detail panel to the bottom")
                    : L10n.t("Dock detail panel to the right"))
        .accessibilityValue(vm.detailPanelPosition == .right
                            ? L10n.t("Currently docked right") : L10n.t("Currently docked bottom"))
    }
}
