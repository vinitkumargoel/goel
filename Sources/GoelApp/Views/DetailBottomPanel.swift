import SwiftUI
import Combine
import GoelCore

/// The detail panel as it appears when docked to the **bottom** edge — the
/// "Command Center" layout: wide and short, split into three side-by-side zones
/// that each own the horizontal room a bottom dock gives you.
///
///  1. **Identity + actions** (fixed) — icon, name, kind/status, a live progress
///     bar, and the primary controls (pause/resume/retry, reveal, copy).
///  2. **Live telemetry** (fixed) — a rolling throughput sparkline with the
///     current ↓ rate, and a strip of ↑ / ETA / swarm figures.
///  3. **Tabbed detail** (flexible) — the five tabs. *General* is the headline
///     percent + key facts; *Details / Progress / Files / Connections* are the
///     same deep views the right dock shows, given the width to breathe.
struct DetailBottomPanel: View {
    @EnvironmentObject private var vm: AppViewModel

    /// Rolling download-speed history for zone 2's sparkline. Sized to 60 so the
    /// once-a-second cadence gives a full 60-second window, matching the caption.
    @StateObject private var sampler = ThroughputSampler(capacity: 60)
    /// Samples the selected task's speed on a steady once-a-second cadence, so
    /// the graph advances even when the rate holds constant.
    @State private var sampleTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
        .onReceive(sampleTimer) { _ in
            sampler.record(task.downloadSpeed, id: AnyHashable(task.id))
        }
    }

    // MARK: - Zone 1 · identity + actions

    private func summaryZone(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                FileTypeIcon(type: task.fileType, size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 7) {
                        KindBadge(task: task)
                        DetailStatusPill(task: task)
                    }
                }
                Spacer(minLength: 0)
            }

            MiniProgressBar(task: task, height: 6)

            if case .failed(let error) = task.status {
                Text(error.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.red)
                    .lineLimit(2)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }

            Spacer(minLength: 0)

            DetailActionButtons(task: task, vm: vm)
        }
        .padding(16)
    }

    // MARK: - Zone 2 · live telemetry

    private func telemetryZone(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LIVE THROUGHPUT")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                ThroughputGraph(samples: sampler.samples)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.displaySpeed(for: task).down > 0 ? vm.displaySpeed(for: task).down.speedString : "—")
                        .font(.system(size: 16, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(vm.displaySpeed(for: task).down > 0 ? Theme.green : Color.secondary)
                    Text("last 60s").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .fixedSize()
            }

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 16) {
                telStat("Up") {
                    DetailSpeedStat(symbol: "arrow.up", speed: task.uploadSpeed, color: Theme.teal, size: 12)
                }
                telStat("ETA") {
                    Text(task.etaText ?? "—")
                        .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                }
                telStat(task.swarmSummary.label) {
                    Text(task.swarmSummary.value)
                        .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
    }

    /// A small stacked "LABEL / value" cell for the telemetry strip.
    private func telStat<Content: View>(_ label: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    // MARK: - Zone 3 · tabbed detail

    private func detailZone(for task: DownloadTask) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $vm.detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 440)
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

    /// *General* is a compact headline (percent + size) over the key facts, since
    /// zones 1–2 already carry identity, progress and live speed. The other four
    /// reuse the shared tab bodies at a comfortable width.
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
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                Spacer()
                Text(task.sizeProgressText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            if task.kind == .torrent {
                KVRow(key: "Uploaded", value: task.bytesUploaded.byteString)
                KVRow(key: "Share ratio", value: String(format: "%.2f", task.shareRatio))
            }
            KVRow(key: "Priority", value: task.priority.displayName)
            KVRow(key: "Added", value: task.addedString)
            KVRow(key: "Save path", value: task.savePath, copyable: true)
            KVRow(key: "Source", value: task.sourceLocator, copyable: true)

            // The overlaid download + upload speed history. Self-hiding until it
            // has enough samples, so it only appears for actively-transferring
            // tasks that have accumulated a history.
            TaskSpeedGraph(taskID: task.id)
                .padding(.top, 14)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                PanelDockToggle()
            }
            .padding(12)
            Spacer(minLength: 0)
            HStack(spacing: 13) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundStyle(.quaternary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No selection")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                    Text("Select a download to see its details, progress, and live throughput.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The right/bottom dock toggle shared by both detail panels. The icon previews
/// the *destination* dock; the choice is persisted, so it holds across
/// selections and survives relaunch until the user flips it again.
struct PanelDockToggle: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        Button {
            vm.toggleDetailPanelPosition()
        } label: {
            Image(systemName: vm.detailPanelPosition == .right
                  ? "rectangle.bottomhalf.inset.filled"
                  : "rectangle.trailinghalf.inset.filled")
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(vm.detailPanelPosition == .right ? "Dock panel to bottom" : "Dock panel to right")
    }
}
