import SwiftUI
import GoelCore

struct DetailPanelView: View {
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
        .clipped()
    }

    private func content(for task: DownloadTask) -> some View {
        VStack(spacing: 0) {
            header(for: task)
            Divider()

            // Five segments truncate ("Connecti…") below ~360 pt, so the picker becomes a menu there.
            DetailTabPicker(selection: $vm.detailTab, segmentedMinWidth: 336)
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
                DetailTitle(name: task.name)
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
                        .scaledFont(size: Theme.TextSize.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityLabel(L10n.t("Download progress"))
            .accessibilityValue(task.accessibilityProgressValue)

            HStack(spacing: 22) {
                DetailSpeedStat(symbol: "arrow.down", speed: telemetry.displaySpeed(for: task).down, color: Theme.green, size: 13)
                DetailSpeedStat(symbol: "arrow.up", speed: telemetry.displaySpeed(for: task).up, color: Theme.teal, size: 13)
            }

            Text(sizeAndETA(for: task))
                .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .accessibilityLabel(A11y.sentence(
                    L10n.t("%1$@ of %2$@", A11y.bytes(task.bytesDownloaded), A11y.bytes(task.totalBytes)),
                    A11y.eta(task.estimatedTimeRemaining)))

            if case .failed(let error) = task.status {
                FailureCard(task: task, error: error, vm: vm)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
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

/// Segmented while there is room for every tab label, a pop-up menu otherwise.
struct DetailTabPicker: View {
    @Binding var selection: DetailTab
    /// Below this width the segmented labels truncate.
    let segmentedMinWidth: CGFloat
    var segmentedMaxWidth: CGFloat? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented)
                .frame(minWidth: segmentedMinWidth, maxWidth: segmentedMaxWidth ?? .infinity)
            picker.pickerStyle(.menu)
                .fixedSize()
        }
        .accessibilityLabel(L10n.t("Detail section"))
    }

    private var picker: some View {
        Picker("", selection: $selection) {
            ForEach(DetailTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .labelsHidden()
    }
}
