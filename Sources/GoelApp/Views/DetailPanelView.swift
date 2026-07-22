import SwiftUI
import GoelCore

/// The right detail panel — the "Hero Ring" layout. A narrow, tall column, so
/// the progress is expressed as a big circular gauge you can read at a glance,
/// with the live ↓/↑ rate beneath it, the essential facts as a short list, and a
/// pinned action bar (pause/resume/retry, reveal, copy) that never scrolls away.
struct DetailPanelView: View {
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
        // Never let the panel's content bleed past its 340pt frame.
        .clipped()
    }

    private func content(for task: DownloadTask) -> some View {
        VStack(spacing: 0) {
            header(for: task)
            Divider()

            // The tabs — `.small` keeps all five segments legible in the narrow
            // 340pt column. *General* is the hero-ring overview; the rest are the
            // same deep views as before.
            Picker("", selection: $vm.detailTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            ScrollView {
                tabBody(for: task)
            }
            Divider()
            DetailActionButtons(task: task, vm: vm, fill: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }

    @ViewBuilder
    private func tabBody(for task: DownloadTask) -> some View {
        switch vm.detailTab {
        case .general:
            VStack(spacing: 0) {
                hero(for: task)
                facts(for: task)
            }
        case .details:
            DetailsTab(task: task).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        case .progress:
            ProgressTab(task: task).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        case .files:
            FilesTab(task: task).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        case .connections:
            ConnectionsTab(task: task).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private func header(for task: DownloadTask) -> some View {
        HStack(spacing: 11) {
            FileTypeIcon(type: task.fileType, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 7) {
                    KindBadge(task: task)
                    DetailStatusPill(task: task)
                }
            }
            Spacer(minLength: 8)
            PanelDockToggle()
        }
        .padding(16)
    }

    // MARK: - Hero ring

    private func hero(for task: DownloadTask) -> some View {
        VStack(spacing: 14) {
            ZStack {
                ProgressRing(fraction: task.fractionCompleted, tint: task.progressTint)
                    .frame(width: 132, height: 132)
                VStack(spacing: 1) {
                    Text("\(task.percentComplete)%")
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                    Text("complete")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)

            HStack(spacing: 22) {
                DetailSpeedStat(symbol: "arrow.down", speed: vm.displaySpeed(for: task).down, color: Theme.green, size: 13)
                DetailSpeedStat(symbol: "arrow.up", speed: vm.displaySpeed(for: task).up, color: Theme.teal, size: 13)
            }

            Text(sizeAndETA(for: task))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if case .failed(let error) = task.status {
                Text("⚠ \(error.message)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Theme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    /// "244.50 MB of 770.31 MB · ~6m" — size with the ETA appended when known.
    private func sizeAndETA(for task: DownloadTask) -> String {
        if let eta = task.etaText { return "\(task.sizeProgressText) · \(eta)" }
        return task.sizeProgressText
    }

    // MARK: - Facts

    private func facts(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if task.kind == .torrent {
                KVRow(key: "Share ratio", value: String(format: "%.2f", task.shareRatio))
                KVRow(key: "Uploaded", value: task.bytesUploaded.byteString)
                KVRow(key: "Peers", value: task.swarmSummary.value)
                KVRow(key: "Leechers", value: "\(task.leecherCount)")
                if let limit = task.seedRatioLimit, limit > 0 {
                    let pct = Int(((task.seedRatioProgress ?? 0) * 100).rounded())
                    KVRow(key: "Seed target",
                          value: String(format: "ratio %.1f · %d%%", limit, pct),
                          valueColor: Theme.teal)
                }
            } else {
                KVRow(key: "Connections", value: "\(task.connectionCount)")
            }
            if let label = task.label {
                KVRow(key: "Label", value: label, valueColor: Theme.accent)
            }
            if !task.allTags.isEmpty {
                KVRow(key: "Tags", value: task.allTags.joined(separator: ", "), valueColor: Theme.teal)
            }
            if let note = task.note, !note.isEmpty {
                KVRow(key: "Note", value: note)
            }
            if let referer = task.referer, !referer.isEmpty {
                KVRow(key: "Referer", value: referer, copyable: true)
            }
            if let headers = task.requestHeaders, !headers.isEmpty {
                KVRow(key: "Headers", value: "\(headers.count) custom")
            }
            KVRow(key: "Priority", value: task.priority.displayName)
            KVRow(key: "Added", value: task.addedString)
            KVRow(key: "Save path", value: task.savePath, copyable: true)
            if let destination = task.remoteDestination {
                KVRow(key: "Server", value: destination.displayLocation, copyable: true)
                if let status = vm.remoteStatusText(task) { KVRow(key: "Transfer", value: status) }
                if let remotePath = destination.remotePath {
                    KVRow(key: "Server path", value: remotePath, copyable: true)
                }
            }
            KVRow(key: "Source", value: task.sourceLocator, copyable: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 0) {
            // Keep the dock toggle reachable even with nothing selected, so the
            // panel can be moved back without first picking a download.
            HStack {
                Spacer(minLength: 0)
                PanelDockToggle()
            }
            .padding(12)
            Spacer(minLength: 0)
            EmptyStateView(systemImage: "doc.text.magnifyingglass",
                           title: "No selection",
                           subtitle: "Select a download to see its progress, live speed, and details.",
                           symbolSize: 40)
                .padding(.horizontal, 30)
            Spacer(minLength: 0)
        }
    }
}
