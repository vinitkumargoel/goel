import SwiftUI
import GoelCore

struct DetailPanelView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        Group {
            if vm.selectedTasks.count > 1 {
                MultiSelectionPanel()
            } else if let task = vm.selectedTask {
                content(for: task)
            } else {
                QueueOverviewPanel()
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

            DetailTabPicker(selection: $vm.detailTab, tabs: DetailTab.available(for: task))
                .controlSize(.small)
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
        switch vm.detailTab.resolved(for: task) {
        case .overview:
            VStack(spacing: 0) {
                if task.status == .completed {
                    CompletedHero(task: task, vm: vm)
                } else {
                    hero(for: task)
                }
                if task.showsProgressDetail {
                    ProgressTab(task: task)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                facts(for: task)
            }
        case .files:
            FilesTab(task: task).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        case .network:
            VStack(alignment: .leading, spacing: 18) {
                DetailsTab(task: task)
                ConnectionsTab(task: task)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(for task: DownloadTask) -> some View {
        HStack(spacing: 11) {
            FileTypeIcon(type: task.fileType, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                DetailTitle(name: task.compactDisplayName)
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

    /// Ring and numbers side by side instead of stacked: about 120 pt shorter, which brings the
    /// save path and source above the fold at the window's minimum height.
    private func hero(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    ProgressRing(fraction: task.fractionCompleted, tint: task.progressTint)
                        .frame(width: 88, height: 88)
                    Text("\(task.percentComplete)%")
                        .scaledFont(size: 20, weight: .bold, monospacedDigit: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityLabel(L10n.t("Download progress"))
                .accessibilityValue(task.accessibilityProgressValue)

                VStack(alignment: .leading, spacing: 6) {
                    DetailSpeedStat(symbol: "arrow.down", speed: telemetry.displaySpeed(for: task).down,
                                    color: Theme.green, size: 15)
                    DetailSpeedStat(symbol: "arrow.up", speed: telemetry.displaySpeed(for: task).up,
                                    color: Theme.teal, size: 12)
                    Text(sizeAndETA(for: task))
                        .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(A11y.sentence(
                            L10n.t("%1$@ of %2$@", A11y.bytes(task.bytesDownloaded), A11y.bytes(task.totalBytes)),
                            A11y.eta(task.estimatedTimeRemaining)))
                }
                Spacer(minLength: 0)
            }

            TaskSpeedGraph(taskID: task.id, window: 60, height: 44)

            if case .failed(let error) = task.status {
                FailureCard(task: task, error: error, vm: vm)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private func sizeAndETA(for task: DownloadTask) -> String {
        if let eta = task.etaText { return L10n.t("%1$@ · %2$@", task.sizeProgressText, eta) }
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
            KVRow(key: L10n.t("Priority"), value: task.priority.title)
            KVRow(key: L10n.t("Added"), value: task.addedString)
            if task.status == .completed, let completedAt = task.completedAt {
                KVRow(key: L10n.t("Finished"), value: DownloadTask.addedString(for: completedAt))
                if let took = CompletionSummary.tookLine(bytes: CompletionSummary.size(of: task),
                                                         addedAt: task.addedAt, completedAt: completedAt) {
                    KVRow(key: L10n.t("Took"), value: took)
                }
            }
            KVRow(key: L10n.t("Save path"), value: task.savePath, copyable: true)
            KVRow(key: L10n.t("Source"), value: task.sourceLocator, copyable: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

/// The download's name as the panel heading. Middle truncation keeps the extension visible,
/// and the name can be selected and copied.
struct DetailTitle: View {
    let name: String

    var body: some View {
        Text(name)
            .scaledFont(size: Theme.TextSize.title, weight: .semibold)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(name)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Segmented while there is room for every tab label, a pop-up menu otherwise. The three short
/// labels fit segmented in the right panel; the menu is only the large-text fallback.
struct DetailTabPicker: View {
    @Binding var selection: DetailTab
    let tabs: [DetailTab]
    var segmentedMaxWidth: CGFloat? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented)
                .frame(maxWidth: segmentedMaxWidth ?? .infinity)
            picker.pickerStyle(.menu)
                .fixedSize()
        }
        .accessibilityLabel(L10n.t("Detail section"))
    }

    /// Bound through the drawn tab, so a Files choice remembered from a torrent shows Overview
    /// selected on a single file rather than no segment at all.
    private var picker: some View {
        Picker("", selection: Binding(get: { tabs.contains(selection) ? selection : .overview },
                                      set: { selection = $0 })) {
            ForEach(tabs) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .labelsHidden()
    }
}
