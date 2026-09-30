import SwiftUI
import GoelCore

/// The detail panel while several rows are selected: what the selection adds up to, and the
/// bulk commands the list's context menu offers — calling the same view-model methods.
/// Tall on the right; in the bottom dock the same parts sit in three zones on one row, so the
/// actions stay above the fold of a 300 pt dock.
struct MultiSelectionPanel: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    var horizontal = false

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

    private func sideLayout(_ summary: SelectionAggregate, queue: QueueOverview) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                PanelDockToggle()
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, 10)
            ScrollView {
                VStack(spacing: Theme.Space.l) {
                    tileStack(summary.preview)
                        .padding(.top, Theme.Space.xs)
                    titles(summary, alignment: .center)
                    ring(summary, size: 104, fontSize: 22)
                    HStack(spacing: 22) {
                        DetailSpeedStat(symbol: "arrow.down", speed: summary.speed.down, color: Theme.green, size: 13)
                        DetailSpeedStat(symbol: "arrow.up", speed: summary.speed.up, color: Theme.teal, size: 13)
                    }
                    if let eta = etaText(queue) {
                        Text(eta)
                            .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                            .foregroundStyle(.secondary)
                    }
                    primaryActions(summary)
                    secondaryActions(summary)
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, 18)
            }
        }
    }

    private func bottomLayout(_ summary: SelectionAggregate, queue: QueueOverview) -> some View {
        HStack(spacing: Theme.Space.xl) {
            HStack(spacing: Theme.Space.m) {
                tileStack(summary.preview)
                titles(summary, alignment: .leading)
            }
            .frame(minWidth: 220, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.t("%d%% combined", Int((summary.fraction * 100).rounded())))
                        .scaledFont(size: Theme.TextSize.meta, weight: .semibold, monospacedDigit: true)
                    Spacer(minLength: Theme.Space.s)
                    DetailSpeedStat(symbol: "arrow.down", speed: summary.speed.down, color: Theme.green, size: 12)
                    if let eta = etaText(queue) {
                        Text(eta)
                            .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: summary.fraction)
                    .tint(summary.failedCount == summary.count ? Theme.red : Theme.accent)
                    .accessibilityLabel(L10n.t("Combined progress"))
                    .accessibilityValue(A11y.percent(summary.fraction))
            }
            .frame(minWidth: 180, maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: Theme.Space.s) {
                HStack(spacing: 6) {
                    compactActions(summary)
                    PanelDockToggle()
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func titles(_ summary: SelectionAggregate, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Theme.Space.xs) {
            Text(summary.title)
                .scaledFont(size: Theme.TextSize.title, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            if !summary.subtitle.isEmpty {
                Text(summary.subtitle)
                    .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    private func ring(_ summary: SelectionAggregate, size: CGFloat, fontSize: CGFloat) -> some View {
        ZStack {
            ProgressRing(fraction: summary.fraction,
                         tint: summary.failedCount == summary.count ? Theme.red : Theme.accent)
                .frame(width: size, height: size)
            Text("\(Int((summary.fraction * 100).rounded()))%")
                .scaledFont(size: fontSize, weight: .bold, monospacedDigit: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(L10n.t("Combined progress"))
        .accessibilityValue(A11y.percent(summary.fraction))
    }

    private func etaText(_ queue: QueueOverview) -> String? {
        guard let eta = queue.eta else { return nil }
        return L10n.t("%@ left", DownloadTask.etaString(eta))
    }

    /// Up to three file tiles fanned out, the first on top.
    private func tileStack(_ tasks: [DownloadTask]) -> some View {
        ZStack {
            ForEach(Array(tasks.enumerated().reversed()), id: \.element.id) { index, task in
                FileTypeIcon(type: task.fileType, size: horizontal ? 36 : 48)
                    .rotationEffect(.degrees(Double(index) * 8))
                    .offset(x: CGFloat(index) * (horizontal ? 10 : 14), y: CGFloat(index) * -3)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
        }
        .frame(width: horizontal ? 64 : 96, height: horizontal ? 48 : 64)
        .a11yDecorative()
    }

    private func primaryActions(_ summary: SelectionAggregate) -> some View {
        let count = summary.count
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s),
                                   GridItem(.flexible(), spacing: Theme.Space.s)],
                         spacing: Theme.Space.s) {
            action(L10n.t("Resume"), "play.fill", spoken: L10n.t("Resume %d Selected", count),
                   enabled: summary.canResume, prominent: summary.canResume) { vm.resumeSelected() }
            action(L10n.t("Pause"), "pause.fill", spoken: L10n.t("Pause %d Selected", count),
                   enabled: summary.canPause) { vm.pauseSelected() }
            action(L10n.t("Retry"), "arrow.clockwise", spoken: L10n.t("Retry %d Selected", count),
                   enabled: summary.canRetry) { vm.retrySelected() }
            action(L10n.t("Move to…"), "folder", spoken: L10n.t("Move %d selected downloads", count),
                   enabled: summary.canMove) { chooseFolder(count) }
            action(L10n.t("To Top"), "arrow.up.to.line", spoken: L10n.t("Move %d to the top of the queue", count)) {
                vm.moveSelectedInQueue(to: .top)
            }
            action(L10n.t("To Bottom"), "arrow.down.to.line", spoken: L10n.t("Move %d to the bottom of the queue", count)) {
                vm.moveSelectedInQueue(to: .bottom)
            }
        }
    }

    /// The less frequent commands, kept in one row so the panel doesn't grow a third grid.
    private func secondaryActions(_ summary: SelectionAggregate) -> some View {
        let count = summary.count
        return HStack(spacing: Theme.Space.s) {
            priorityMenu(count)
            IconButton(symbol: "magnifyingglass", help: L10n.t("Show in Finder"), size: 13) { vm.revealSelected() }
            IconButton(symbol: "link", help: L10n.t("Copy %d Source Links", count), size: 13) { vm.copySelectedLinks() }
            IconButton(symbol: "tag", help: L10n.t("Add tags to %d downloads", count), size: 13) {
                vm.promptForTagsOnSelection()
            }
            Spacer(minLength: 0)
            removeMenu(count)
        }
    }

    /// The bottom dock's single row: the verbs that apply, then a More menu for the rest.
    @ViewBuilder
    private func compactActions(_ summary: SelectionAggregate) -> some View {
        let count = summary.count
        if summary.canResume {
            Button(L10n.t("Resume")) { vm.resumeSelected() }
                .buttonStyle(TintedPillButtonStyle(tint: Theme.accent, prominent: true))
                .a11yButton(L10n.t("Resume %d Selected", count))
        }
        if summary.canPause {
            Button(L10n.t("Pause")) { vm.pauseSelected() }
                .buttonStyle(TintedPillButtonStyle(tint: Color.primary))
                .a11yButton(L10n.t("Pause %d Selected", count))
        }
        if summary.canRetry {
            Button(L10n.t("Retry")) { vm.retrySelected() }
                .buttonStyle(TintedPillButtonStyle(tint: Theme.red))
                .a11yButton(L10n.t("Retry %d Selected", count))
        }
        Button(L10n.t("To Top")) { vm.moveSelectedInQueue(to: .top) }
            .buttonStyle(TintedPillButtonStyle(tint: Color.primary))
            .a11yButton(L10n.t("Move %d to the top of the queue", count))
        priorityMenu(count)
        Menu {
            Button(L10n.t("Move to Bottom")) { vm.moveSelectedInQueue(to: .bottom) }
            Button(L10n.t("Move to…")) { chooseFolder(count) }.disabled(!summary.canMove)
            Button(L10n.t("Show in Finder")) { vm.revealSelected() }
            Button(L10n.t("Copy %d Source Links", count)) { vm.copySelectedLinks() }
            Button(L10n.t("Add Tags…")) { vm.promptForTagsOnSelection() }
            Divider()
            Button(L10n.t("Remove %d from List", count), role: .destructive) { vm.removeSelected(deleteData: false) }
            Button(L10n.t("Remove %d and Move Files to Trash", count), role: .destructive) {
                vm.confirmMoveSelectionToTrash()
            }
        } label: {
            Label(L10n.t("More"), systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.t("More actions for %d downloads", count))
    }

    private func priorityMenu(_ count: Int) -> some View {
        Menu {
            ForEach([FilePriority.high, .normal, .low], id: \.self) { priority in
                Button(priority.title) { vm.setPrioritySelected(priority) }
            }
        } label: {
            Label(L10n.t("Priority"), systemImage: "flag")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.t("Set the priority of %d downloads", count))
        .accessibilityLabel(L10n.t("Priority for %d downloads", count))
    }

    private func removeMenu(_ count: Int) -> some View {
        Menu {
            Button(L10n.t("Remove %d from List", count), role: .destructive) { vm.removeSelected(deleteData: false) }
            Button(L10n.t("Remove %d and Move Files to Trash", count), role: .destructive) {
                vm.confirmMoveSelectionToTrash()
            }
        } label: {
            Label(L10n.t("Remove"), systemImage: "trash")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(Theme.red)
        .accessibilityLabel(L10n.t("Remove %d downloads", count))
    }

    private func chooseFolder(_ count: Int) {
        if let url = FilePicker.chooseDirectory(prompt: L10n.t("Move Here"),
                                                message: L10n.t("Choose a folder for %d downloads.", count)) {
            vm.moveSelected(to: url.path)
        }
    }

    private func action(_ title: String, _ symbol: String, spoken: String, enabled: Bool = true,
                        prominent: Bool = false, tint: Color = Color.primary,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
        }
        .buttonStyle(TintedPillButtonStyle(tint: prominent ? Theme.accent : tint,
                                           prominent: prominent, fillWidth: true))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .a11yButton(spoken)
    }
}
