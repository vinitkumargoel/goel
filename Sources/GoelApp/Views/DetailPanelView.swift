import SwiftUI
import GoelCore

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
        .clipped()
    }

    private func content(for task: DownloadTask) -> some View {
        VStack(spacing: 0) {
            header(for: task)
            Divider()

            Picker("", selection: $vm.detailTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(L10n.t(tab.rawValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .accessibilityLabel(L10n.t("Detail section"))
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

    private func header(for task: DownloadTask) -> some View {
        HStack(spacing: 11) {
            FileTypeIcon(type: task.fileType, size: 38)
            VStack(alignment: .leading, spacing: 3) {
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
            Spacer(minLength: 8)
            PanelDockToggle()
        }
        .padding(16)
    }

    private func hero(for task: DownloadTask) -> some View {
        VStack(spacing: 14) {
            ZStack {
                ProgressRing(fraction: task.fractionCompleted, tint: task.progressTint)
                    .frame(width: 132, height: 132)
                VStack(spacing: 1) {
                    Text("\(task.percentComplete)%")
                        .scaledFont(size: 30, weight: .bold, monospacedDigit: true)
                    Text(L10n.t("complete"))
                        .scaledFont(size: 10.5)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityLabel(L10n.t("Download progress"))
            .accessibilityValue(task.accessibilityProgressValue)

            HStack(spacing: 22) {
                DetailSpeedStat(symbol: "arrow.down", speed: vm.displaySpeed(for: task).down, color: Theme.green, size: 13)
                DetailSpeedStat(symbol: "arrow.up", speed: vm.displaySpeed(for: task).up, color: Theme.teal, size: 13)
            }

            Text(sizeAndETA(for: task))
                .scaledFont(size: 11.5, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .accessibilityLabel(A11y.sentence(
                    L10n.t("%1$@ of %2$@", A11y.bytes(task.bytesDownloaded), A11y.bytes(task.totalBytes)),
                    A11y.eta(task.estimatedTimeRemaining)))

            if case .failed(let error) = task.status {
                Text("⚠ \(error.message)")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Theme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(L10n.t("Download failed. %@", error.message))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private func sizeAndETA(for task: DownloadTask) -> String {
        if let eta = task.etaText { return "\(task.sizeProgressText) · \(eta)" }
        return task.sizeProgressText
    }

    private func facts(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if task.kind == .torrent {
                KVRow(key: L10n.t("Share ratio"), value: String(format: "%.2f", task.shareRatio))
                KVRow(key: L10n.t("Uploaded"), value: task.bytesUploaded.byteString)
                KVRow(key: L10n.t("Peers"), value: task.swarmSummary.value)
                KVRow(key: L10n.t("Leechers"), value: "\(task.leecherCount)")
                if let limit = task.seedRatioLimit, limit > 0 {
                    let pct = Int(((task.seedRatioProgress ?? 0) * 100).rounded())
                    KVRow(key: L10n.t("Seed target"),
                          value: L10n.t("ratio %.1f · %d%%", limit, pct),
                          valueColor: Theme.teal)
                }
            } else {
                KVRow(key: L10n.t("Connections"), value: "\(task.connectionCount)")
            }
            if let label = task.label {
                KVRow(key: L10n.t("Label"), value: label, valueColor: Theme.accent)
            }
            if !task.allTags.isEmpty {
                KVRow(key: L10n.t("Tags"), value: task.allTags.joined(separator: ", "), valueColor: Theme.teal)
            }
            if let note = task.note, !note.isEmpty {
                KVRow(key: L10n.t("Note"), value: note)
            }
            if let referer = task.referer, !referer.isEmpty {
                KVRow(key: L10n.t("Referer"), value: referer, copyable: true)
            }
            if let headers = task.requestHeaders, !headers.isEmpty {
                KVRow(key: L10n.t("Headers"), value: L10n.t("%d custom", headers.count))
            }
            // Cookie STATE only — never the value, and never `copyable`.
            if let cookieSource = task.cookieSource, cookieSource != .none {
                KVRow(key: L10n.t("Cookies"),
                      value: task.cookieHeader.map {
                          L10n.t("%1$@ attached · %2$@",
                                 String(CookieHeader.count(in: $0)), cookieSource.displayName)
                      } ?? L10n.t("Not loaded — re-import from %@", cookieSource.displayName))
            }
            KVRow(key: L10n.t("Priority"), value: L10n.t(task.priority.displayName))
            KVRow(key: L10n.t("Added"), value: task.addedString)
            KVRow(key: L10n.t("Save path"), value: task.savePath, copyable: true)
            KVRow(key: L10n.t("Source"), value: task.sourceLocator, copyable: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
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
                           subtitle: L10n.t("Select a download to see its progress, live speed, and details."),
                           symbolSize: 40)
                .padding(.horizontal, 30)
            Spacer(minLength: 0)
        }
    }
}
