import SwiftUI
import GoelCore

/// The center list: a sortable header and selectable rows with inline progress,
/// type badge, and per-row state button. Columns: #, Name, Size, Status, Added,
/// ↓ Speed, ↑ Speed.
struct DownloadListView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.visibleTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.visibleTasks.enumerated()), id: \.element.id) { index, task in
                            DownloadRow(
                                task: task,
                                displayIndex: index + 1,
                                isSelected: vm.selection == task.id,
                                vm: vm
                            )
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            headerCol("#", .index, width: 30, alignment: .center)
            headerCol("Name", .name, width: nil, alignment: .leading)
            headerCol("Size", .size, width: 84, alignment: .trailing)
            headerCol("Status", .status, width: 130, alignment: .leading)
            headerCol("Added", .added, width: 104, alignment: .leading)
            headerCol("↓ Speed", .downloadSpeed, width: 84, alignment: .trailing)
            headerCol("↑ Speed", .uploadSpeed, width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func headerCol(_ title: String, _ key: SortKey, width: CGFloat?, alignment: Alignment) -> some View {
        Button {
            vm.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                if vm.sortKey == key {
                    Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                if alignment != .trailing { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .padding(.horizontal, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 38))
                .foregroundStyle(.quaternary)
            Text("No downloads match")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Try a different filter or search term.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row in the download list.
///
/// `vm` is held as a plain (non-observed) reference and `isSelected` is passed in
/// by the parent, so a row's `body` re-runs only when its own value inputs
/// (`task`, `isSelected`, `displayIndex`) change — not on every progress tick of
/// some *other* task. (Previously every row observed the whole view model and all
/// rows rebuilt on each publish.)
struct DownloadRow: View {
    let task: DownloadTask
    let displayIndex: Int
    let isSelected: Bool
    let vm: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            Text("\(displayIndex)")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 30)
                .padding(.horizontal, 6)

            nameCell
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            Text(task.totalBytes?.byteString ?? "—")
                .frame(width: 84, alignment: .trailing)
                .padding(.horizontal, 6)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack(spacing: 6) {
                Circle().fill(task.statusColor).frame(width: 7, height: 7)
                Text(task.statusDetailText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
            .padding(.horizontal, 6)

            Text(task.addedString)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
                .padding(.horizontal, 6)

            Text(task.downloadSpeed.speedString)
                .frame(width: 84, alignment: .trailing)
                .padding(.horizontal, 6)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(task.downloadSpeed > 0 ? Theme.green : Color.secondary)
                .monospacedDigit()

            Text(task.uploadSpeed.speedString)
                .frame(width: 84, alignment: .trailing)
                .padding(.horizontal, 6)
                .font(.system(size: 12.5))
                .foregroundStyle(task.uploadSpeed > 0 ? Theme.teal : Color.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .background(isSelected ? Theme.accent.opacity(0.22) : (displayIndex.isMultiple(of: 2) ? Theme.rowAlt : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            vm.selection = task.id
            if !vm.detailPanelVisible { vm.detailPanelVisible = true }
        }
        .contextMenu { contextMenu }
    }

    private var nameCell: some View {
        HStack(spacing: 10) {
            StateButton(task: task, vm: vm)
            FileTypeIcon(type: task.fileType)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(task.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    KindBadge(task: task)
                }
                MiniProgressBar(task: task)
                    .frame(maxWidth: 340)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if task.status == .paused || task.status == .queued {
            Button("Resume") { vm.resume(task.id) }
        } else if task.status.isActive {
            Button("Pause") { vm.pause(task.id) }
        }
        if isFailed { Button("Retry") { vm.retry(task.id) } }
        Button("Open folder") { vm.revealInFinder(task) }
        Button("Copy source link") { vm.copyToPasteboard(task.sourceLocator) }
        Divider()
        Button("Remove from list", role: .destructive) { vm.remove(task.id, deleteData: false) }
        Button("Remove with data", role: .destructive) { vm.remove(task.id, deleteData: true) }
    }

    private var isFailed: Bool {
        if case .failed = task.status { return true }
        return false
    }
}
