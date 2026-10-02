import SwiftUI
import GoelCore

/// The List: a dense, sortable table on a card, with optional columns, Regular / Compact rows,
/// Group by headers and drag-to-reorder by the "#" grip.
struct DownloadTableView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    @Binding var columnsRaw: String
    @Binding var density: ListDensity
    let inputs: DownloadItemInputs

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Grows the fixed columns with the text size, the same factor `studioFont` applies.
    @ScaledMetric(relativeTo: .body) private var widthScale: CGFloat = 100

    /// Measured, so the column set follows the list rather than the window.
    @State private var listWidth: CGFloat = 0

    private var columns: DownloadColumns {
        DownloadColumns(scale: widthScale / 100, listWidth: listWidth,
                        chosen: ListColumnPrefs.decode(columnsRaw), density: density)
    }

    var body: some View {
        let columns = self.columns
        VStack(spacing: 0) {
            DownloadTableHeader(columns: columns, columnsRaw: $columnsRaw, density: $density)
                .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { listWidth = $0 }
            StudioDivider()
                .padding(.horizontal, Studio.Space.xs)
            scrollingRows(columns)
        }
        .padding(.horizontal, Studio.Space.xs)
        .padding(.top, Studio.Space.xxs)
        .studioSurface(.card, radius: Studio.Radius.card, elevation: .card)
        .padding(.horizontal, Studio.Space.gutter)
        .padding(.top, Studio.Space.xs)
        .padding(.bottom, Studio.Space.l)
    }

    // Split out of `body`: the whole chain in one expression is slow to type-check.
    private func scrollingRows(_ columns: DownloadColumns) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Pinned, so a long group keeps its name in view while it scrolls.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    groupedRows(columns)
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.selectNone() }
                        .a11yDecorative()
                }
                .padding(.vertical, Studio.Space.xxs)
            }
            .onChange(of: vm.selectedTask?.id) { _, id in
                guard let id else { return }
                // Reduce Motion jumps instead of gliding.
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func groupedRows(_ columns: DownloadColumns) -> some View {
        if vm.grouping == .none {
            rows(vm.visibleTasks, offset: 0, reorderable: vm.isQueueReorderable, columns: columns)
        } else {
            let offsets = sectionOffsets
            ForEach(vm.visibleSections) { section in
                Section {
                    rows(section.tasks, offset: offsets[section.id] ?? 0, reorderable: false, columns: columns)
                } header: {
                    ListSectionHeader(section: section)
                }
            }
        }
    }

    /// Each section's first row index in the flattened list, so "#" runs on across headers
    /// instead of restarting under each one.
    private var sectionOffsets: [String: Int] {
        var offsets: [String: Int] = [:]
        var running = 0
        for section in vm.visibleSections {
            offsets[section.id] = running
            running += section.tasks.count
        }
        return offsets
    }

    private func rows(_ tasks: [DownloadTask], offset: Int, reorderable: Bool,
                      columns: DownloadColumns) -> some View {
        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
            VStack(spacing: 0) {
                HoverTracking(content: row(task, displayIndex: offset + index + 1, reorderable: reorderable,
                                           columns: columns))
                    .modifier(QueueDropTarget(taskID: task.id, enabled: reorderable, vm: vm))
                if index < tasks.count - 1 {
                    StudioDivider()
                        .padding(.horizontal, Studio.Space.m)
                }
            }
            .id(task.id)
        }
    }

    private func row(_ task: DownloadTask, displayIndex: Int, reorderable: Bool,
                     columns: DownloadColumns) -> DownloadTableRow {
        let isSelected = vm.isSelected(task.id)
        return DownloadTableRow(
            task: task,
            displayIndex: displayIndex,
            queueRank: inputs.ranks[task.id],
            reorderable: reorderable,
            isSelected: isSelected,
            // Only a selected row draws focus, so the rest stay equal when focus moves.
            listFocused: inputs.focused && isSelected,
            showsFocusRing: inputs.focused && vm.primarySelection == task.id,
            speed: telemetry.displaySpeed(for: task),
            summary: isSelected ? inputs.summary : nil,
            context: inputs.context,
            columns: columns,
            vm: vm)
    }
}
