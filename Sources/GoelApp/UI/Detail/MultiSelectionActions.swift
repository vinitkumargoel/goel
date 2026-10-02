import SwiftUI
import GoelCore

/// The bulk commands for a multi-row selection. The verbs that apply (Resume, Pause, Retry)
/// lead, the first one filled; then Move to…, Show in Finder and a More menu with the rest:
/// queue order, links, tags, priority and removal. `compact` is the bottom dock's single row.
struct MultiSelectionActions: View {
    let summary: SelectionAggregate
    var compact = false

    @EnvironmentObject private var vm: AppViewModel

    private var count: Int { summary.count }

    var body: some View {
        if compact {
            DetailFlowLayout(spacing: Studio.Space.xs, lineSpacing: Studio.Space.xs) {
                verbs(fullWidth: false)
                Button(L10n.t("To Top"), systemImage: "arrow.up.to.line") { vm.moveSelectedInQueue(to: .top) }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .a11yButton(L10n.t("Move %d to the top of the queue", count))
                priorityMenu
                moreMenu(fullWidth: false)
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Studio.Space.s),
                                GridItem(.flexible(), spacing: Studio.Space.s)],
                      spacing: Studio.Space.s) {
                verbs(fullWidth: true)
                Button(L10n.t("Move to…"), systemImage: "folder.badge.plus") { chooseFolder() }
                    .buttonStyle(.studio(.secondary, fullWidth: true))
                    .disabled(!summary.canMove)
                    .a11yButton(L10n.t("Move %d selected downloads", count))
                Button(L10n.t("Show in Finder"), systemImage: "folder") { vm.revealSelected() }
                    .buttonStyle(.studio(.secondary, fullWidth: true))
                    .a11yButton(L10n.t("Show in Finder"))
                moreMenu(fullWidth: true)
            }
        }
    }

    @ViewBuilder
    private func verbs(fullWidth: Bool) -> some View {
        let size: StudioButtonStyle.Size = compact ? .small : .regular
        if summary.canResume {
            Button(compact ? L10n.t("Resume") : L10n.t("Resume %d", count), systemImage: "play.fill") { vm.resumeSelected() }
                .buttonStyle(.studio(.primary, size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Resume %d Selected", count))
        }
        if summary.canPause {
            Button(compact ? L10n.t("Pause") : L10n.t("Pause %d", count), systemImage: "pause.fill") { vm.pauseSelected() }
                .buttonStyle(.studio(summary.canResume ? .secondary : .primary, size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Pause %d Selected", count))
        }
        if summary.canRetry {
            Button(compact ? L10n.t("Retry") : L10n.t("Retry %d", count), systemImage: "arrow.clockwise") { vm.retrySelected() }
                .buttonStyle(.studio(summary.canResume || summary.canPause ? .destructive : .primary,
                                     size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Retry %d Selected", count))
        }
    }

    private var priorityMenu: some View {
        DetailMenuButton(title: L10n.t("Priority"), symbol: "flag",
                         accessibilityLabel: L10n.t("Priority for %d downloads", count)) {
            priorityItems
        }
        .help(L10n.t("Set the priority of %d downloads", count))
    }

    @ViewBuilder private var priorityItems: some View {
        ForEach([FilePriority.high, .normal, .low], id: \.self) { priority in
            Button(priority.title) { vm.setPrioritySelected(priority) }
        }
    }

    private func moreMenu(fullWidth: Bool) -> some View {
        DetailMenuButton(title: L10n.t("More"), symbol: "ellipsis.circle",
                         size: compact ? .small : .regular, showsChevron: !fullWidth, fullWidth: fullWidth,
                         accessibilityLabel: L10n.t("More actions for %d downloads", count)) {
            if !compact {
                Button(L10n.t("Move to Top")) { vm.moveSelectedInQueue(to: .top) }
            }
            Button(L10n.t("Move to Bottom")) { vm.moveSelectedInQueue(to: .bottom) }
            if compact {
                Button(L10n.t("Move to…")) { chooseFolder() }.disabled(!summary.canMove)
                Button(L10n.t("Show in Finder")) { vm.revealSelected() }
            }
            Divider()
            Button(L10n.t("Copy %d Source Links", count)) { vm.copySelectedLinks() }
            Button(L10n.t("Add Tags…")) { vm.promptForTagsOnSelection() }
            if !compact {
                Menu(L10n.t("Priority")) { priorityItems }
            }
            Divider()
            Button(L10n.t("Remove %d from List", count), role: .destructive) { vm.removeSelected(deleteData: false) }
            Button(L10n.t("Remove %d and Move Files to Trash", count), role: .destructive) {
                vm.confirmMoveSelectionToTrash()
            }
        }
    }

    private func chooseFolder() {
        if let url = FilePicker.chooseDirectory(prompt: L10n.t("Move Here"),
                                                message: L10n.t("Choose a folder for %d downloads.", count)) {
            vm.moveSelected(to: url.path)
        }
    }
}
