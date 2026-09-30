import SwiftUI
import AppKit
import QuickLook
import GoelCore

struct DownloadListView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore

    @State private var quickLookItem: URL?

    /// Without a default, the window opens with the toolbar's search field as first responder, so
    /// ⌘A and the arrow keys went to an empty text field until the user clicked a row.
    @FocusState private var listFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Grows the fixed columns with the text size, the same factor `scaledFont` applies.
    @ScaledMetric(relativeTo: .body) private var widthScale: CGFloat = 100

    /// Measured, so the column set follows the list rather than the window.
    @State private var listWidth: CGFloat = 0

    private var columns: DownloadColumns { DownloadColumns(scale: widthScale / 100, listWidth: listWidth) }

    var body: some View {
        let content: some View = VStack(spacing: 0) {
            header
            Divider()
            if vm.visibleTasks.isEmpty {
                emptyState
            } else {
                scrollingRows(RowInputs(vm: vm, columns: columns, focused: listFocused))
            }
        }
        return withKeyboard(content
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { listWidth = $0 }
            .contentShape(Rectangle())
            .onTapGesture { vm.selectNone() }
            .quickLookPreview($quickLookItem)
            .environment(\.quickLookAction, QuickLookAction(item: $quickLookItem)))
    }

    /// What every row of one pass shares, worked out once per body instead of per row.
    private struct RowInputs {
        let context: DownloadRow.Context
        let columns: DownloadColumns
        let focused: Bool
        let selectionSummary: DownloadRow.SelectionSummary
        let reorderable: Bool
        let ranks: [DownloadTask.ID: Int]

        @MainActor
        init(vm: AppViewModel, columns: DownloadColumns, focused: Bool) {
            context = DownloadRow.Context(vm: vm)
            self.columns = columns
            self.focused = focused
            selectionSummary = DownloadRow.SelectionSummary(vm.selection.count > 1 ? vm.selectedTasks : [])
            reorderable = vm.isQueueReorderable
            ranks = vm.queueRanks
        }
    }

    // Split out of `body`: the whole chain in one expression took the older CI toolchain ~4 s.
    private func scrollingRows(_ inputs: RowInputs) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Pinned, so a long group keeps its name in view while it scrolls.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    groupedRows(inputs)
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.selectNone() }
                        .a11yDecorative()
                }
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
    private func groupedRows(_ inputs: RowInputs) -> some View {
        if vm.grouping == .none {
            rows(vm.visibleTasks, offset: 0, reorderable: inputs.reorderable, inputs: inputs)
        } else {
            let offsets = sectionOffsets
            ForEach(vm.visibleSections) { section in
                Section {
                    rows(section.tasks, offset: offsets[section.id] ?? 0, reorderable: false, inputs: inputs)
                } header: {
                    ListSectionHeader(section: section)
                }
            }
        }
    }

    private func withKeyboard<Content: View>(_ content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .defaultFocus($listFocused, true)
            // `defaultFocus` alone is not enough: the queue is restored from disk asynchronously, so
            // this view mounts after the window's first-appearance focus pass has already run.
            .task { listFocused = true }
            .onKeyPress { press in handleKey(press) }
            // Delete removes from the list (undoable); ⌘⌫ (see `handleKey`) is the one that trashes files.
            .onDeleteCommand { vm.removeSelected(deleteData: false) }
            .accessibilityLabel(L10n.t("Download queue"))
            .accessibilityHint(L10n.t("Use the up and down arrow keys to move through downloads, shift with an arrow to extend the selection, command A to select all, space to preview, return to open."))
    }

    /// Each section's first row index in the flattened list, so zebra striping and `displayIndex`
    /// run on across headers instead of restarting under each one.
    private var sectionOffsets: [String: Int] {
        var offsets: [String: Int] = [:]
        var running = 0
        for section in vm.visibleSections {
            offsets[section.id] = running
            running += section.tasks.count
        }
        return offsets
    }

    @ViewBuilder
    private func rows(_ tasks: [DownloadTask], offset: Int, reorderable: Bool, inputs: RowInputs) -> some View {
        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
            HoverTrackingRow(row: row(task, displayIndex: offset + index + 1, reorderable: reorderable, inputs: inputs))
            .equatable()
            .modifier(QueueDropTarget(taskID: task.id, enabled: reorderable, vm: vm))
            .id(task.id)
            Divider()
        }
    }

    private func row(_ task: DownloadTask, displayIndex: Int, reorderable: Bool, inputs: RowInputs) -> DownloadRow {
        let isSelected: Bool = vm.isSelected(task.id)
        return DownloadRow(
            task: task,
            displayIndex: displayIndex,
            queueRank: inputs.ranks[task.id],
            reorderable: reorderable,
            isSelected: isSelected,
            // Only a selected row draws focus, so the rest stay equal when focus moves.
            listFocused: inputs.focused && isSelected,
            speed: telemetry.displaySpeed(for: task),
            selectionSummary: isSelected ? inputs.selectionSummary : nil,
            context: inputs.context,
            columns: inputs.columns,
            vm: vm
        )
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let extending = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow, .downArrow:
            guard !press.modifiers.contains(.command) else { return .ignored }
            return vm.moveSelection(by: press.key == .downArrow ? 1 : -1, extending: extending) ? .handled : .ignored
        case .home, .end:
            return vm.selectEdge(last: press.key == .end, extending: extending) ? .handled : .ignored
        case .space:
            guard let task = vm.selectedTask, task.status.hasData else { return .ignored }
            quickLookItem = URL(fileURLWithPath: task.savePath)
            return .handled
        case .return:
            guard let task = vm.selectedTask else { return .ignored }
            if task.status == .completed { vm.openFile(task) } else { vm.revealInFinder(task) }
            return .handled
        case .escape:
            guard !vm.selection.isEmpty else { return .ignored }
            vm.selectNone()
            return .handled
        case .delete where press.modifiers.contains(.command):
            // Here, not as a menu key equivalent: only the focused list may claim ⌘⌫.
            guard vm.selectedTasks.contains(where: { $0.status.hasData }) else { return .ignored }
            vm.confirmMoveSelectionToTrash()
            return .handled
        default:
            // The Edit menu owns ⌘A; this is the fallback for when the list, not a text field,
            // holds focus and no menu item claimed the key first. The character is compared
            // case-insensitively because ⇧⌘A arrives as "A".
            guard press.modifiers.contains(.command),
                  press.key.character.lowercased() == "a" else { return .ignored }
            if extending { vm.selectNone() } else { vm.selectAll() }
            return .handled
        }
    }

    private var header: some View {
        let columns = self.columns
        return HStack(spacing: 0) {
            headerCol(.index, width: columns.index, alignment: .center)
            headerCol(.name, width: nil, alignment: .leading)
            if columns.showsSize {
                headerCol(.size, width: columns.size, alignment: .trailing)
            }
            headerCol(.status, width: columns.status, alignment: .leading)
            if columns.showsAdded {
                headerCol(.added, width: columns.added, alignment: .leading)
            }
            if columns.showsSpeed {
                // One column for both directions; it sorts by download speed. The toolbar's Sort
                // menu can still pick upload speed, and the chevron shows here then too.
                headerCol(.downloadSpeed, width: columns.speed, alignment: .trailing,
                          title: L10n.t("Speed"), alsoSortedBy: [.uploadSpeed])
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func headerCol(_ key: SortKey, width: CGFloat?, alignment: Alignment,
                           title: String? = nil, alsoSortedBy: [SortKey] = []) -> some View {
        let isSortKey = vm.sortKey == key || alsoSortedBy.contains(vm.sortKey)
        Button {
            vm.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title ?? key.columnTitle)
                    .lineLimit(1)
                if isSortKey {
                    Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 8, weight: .bold)
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
        .a11yButton(title ?? key.title,
                    hint: isSortKey
                        ? L10n.t("Currently sorting %@. Activate to reverse.",
                                 vm.sortAscending ? L10n.t("ascending") : L10n.t("descending"))
                        : L10n.t("Activate to sort by this column."))
        .accessibilityValue(isSortKey
                            ? (vm.sortAscending ? L10n.t("Sorted ascending") : L10n.t("Sorted descending"))
                            : L10n.t("Not sorted"))
    }

    private var emptyState: some View {
        let narrowed = vm.filter != .all || !vm.search.isEmpty
        let term = vm.search.trimmingCharacters(in: .whitespacesAndNewlines)
        // Echo the search, as the portal does; a filter alone has no words to echo.
        let title = term.isEmpty ? L10n.t("No downloads match") : L10n.t("No downloads match “%@”", term)
        return EmptyStateView(systemImage: "tray", title: title,
                              subtitle: L10n.t("Try a different filter or search term."),
                              actionTitle: narrowed ? L10n.t("Clear search and filter") : nil,
                              action: narrowed ? { vm.search = ""; vm.filter = .all } : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `vm` is deliberately non-observed: observing it rebuilds every row on every task's progress tick.
/// Everything the body reads is a value property compared in `==`, and `vm` is used only inside
/// actions, so `.equatable()` skips the rows whose data didn't change on a telemetry tick.
struct DownloadRow: View, Equatable {
    let task: DownloadTask
    let displayIndex: Int
    /// The row's place in the queue, which "#" shows whatever the sort.
    var queueRank: Int?
    /// The list is in queue order, so hovering "#" offers a drag grip.
    var reorderable = false
    let isSelected: Bool
    /// Selection is dimmer while focus is elsewhere (the search field), so it's clear where arrows go.
    let listFocused: Bool
    /// Set by ``HoverTrackingRow``; a value, so `.equatable()` still decides every redraw.
    var isHovered = false
    let speed: SpeedSample
    /// Non-nil only for a selected row; `count > 1` means the context menu acts on the selection.
    let selectionSummary: SelectionSummary?
    let context: Context
    let columns: DownloadColumns
    let vm: AppViewModel

    @Environment(\.quickLookAction) private var quickLook

    nonisolated static func == (lhs: DownloadRow, rhs: DownloadRow) -> Bool {
        lhs.task == rhs.task
            && lhs.displayIndex == rhs.displayIndex
            && lhs.queueRank == rhs.queueRank
            && lhs.reorderable == rhs.reorderable
            && lhs.isSelected == rhs.isSelected
            && lhs.listFocused == rhs.listFocused
            && lhs.isHovered == rhs.isHovered
            && lhs.speed == rhs.speed
            && lhs.selectionSummary == rhs.selectionSummary
            && lhs.context == rhs.context
            && lhs.columns == rhs.columns
            && lhs.vm === rhs.vm
    }

    /// App-wide values the row reads, captured once per list body instead of per row. The theme,
    /// language and day are ambient (``ThemePalette/current``, `L10n.currentLanguage`, "today"):
    /// without them here an unchanged row kept its old colours, words or "Today" label.
    struct Context: Equatable {
        var streamLinkPrefix: String?
        var profileSeedRatio: Double
        var themeID = ThemePalette.current.rawValue
        var language = L10n.currentLanguage
        var day = Calendar.current.startOfDay(for: Date())

        @MainActor
        init(vm: AppViewModel) {
            let settings = vm.settings
            if settings.remoteAccessEnabled, !settings.remoteToken.isEmpty {
                // With `remoteTLSEnabled` the socket speaks only TLS; a hardcoded http:// link cannot connect.
                let scheme = settings.remoteTLSEnabled ? "https" : "http"
                streamLinkPrefix = "\(scheme)://127.0.0.1:\(settings.remotePort)/stream?token=\(settings.remoteToken)"
            } else {
                streamLinkPrefix = nil
            }
            profileSeedRatio = settings.effectiveProfile.seedRatioLimit
        }
    }

    /// What the bulk context menu needs to know about the selection, computed once per list body.
    struct SelectionSummary: Equatable {
        var count = 0
        var canResume = false
        var canPause = false
        var canRetry = false
        var canRename = false

        init(_ targets: [DownloadTask]) {
            count = targets.count
            canResume = targets.contains { $0.status == .paused || $0.status == .queued }
            canPause = targets.contains { $0.status.isActive }
            canRetry = targets.contains { $0.status.isFailed }
            canRename = targets.allSatisfy { $0.kind != .torrent && !$0.status.isActive }
        }
    }

    var body: some View {
        withInteractions(withAccessibility(cells
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .background(rowBackground)))
    }

    private var cells: some View {
        HStack(spacing: 0) {
            indexCell
                .frame(width: columns.index)
                .padding(.horizontal, 6)

            nameCell
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            if columns.showsSize {
                Text(task.totalBytes?.byteString ?? "—")
                    .scaledFont(size: Theme.TextSize.body, monospacedDigit: true)
                    .frame(width: columns.size, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .foregroundStyle(.secondary)
            }

            statusCell
                // For a failure the tooltip adds the advice to the reason shown in the cell;
                // otherwise it is the long form the compact cell leaves out.
                .help(failureTooltip ?? task.statusDetailText)
                .frame(width: columns.status, alignment: .leading)
                .padding(.horizontal, 6)

            if columns.showsAdded {
                Text(task.addedColumnString)
                    .scaledFont(size: Theme.TextSize.meta)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(task.addedString)
                    .frame(width: columns.added, alignment: .leading)
                    .padding(.horizontal, 6)
            }

            if columns.showsSpeed {
                speedCell
                    .frame(width: columns.speed, alignment: .trailing)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func withAccessibility<Content: View>(_ content: Content) -> some View {
        let traits: AccessibilityTraits = isSelected
            ? [.isButton, .isSelected, .updatesFrequently]
            : [.isButton, .updatesFrequently]
        let hint: String = failureHint ?? L10n.t("Select to show details.")
        let described = content
            // Label is identity only: folding in the ticking percent makes VoiceOver re-speak the row every second.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(task.accessibilityIdentityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(traits)
            .accessibilityHint(hint)
        return withAccessibilityActions(described)
    }

    private func withAccessibilityActions<Content: View>(_ content: Content) -> some View {
        content
            .accessibilityAction(named: Text(L10n.t(task.accessibilityStateActionName)), primaryStateAction)
            .accessibilityAction(named: Text(L10n.t("Show in Finder"))) { vm.revealInFinder(task) }
            .accessibilityAction(named: Text(L10n.t("Copy source link"))) { vm.copyToPasteboard(task.sourceLocator) }
            .accessibilityAction(named: Text(L10n.t("Remove from list"))) { vm.remove(task.id, deleteData: false) }
            // The keyboard and VoiceOver path to reordering; dragging is pointer-only.
            .accessibilityAction(named: Text(L10n.t("Move to Top of Queue"))) {
                vm.moveInQueue(vm.queueTargets(for: task.id), to: .top)
            }
            .accessibilityAction(named: Text(L10n.t("Move to Bottom of Queue"))) {
                vm.moveInQueue(vm.queueTargets(for: task.id), to: .bottom)
            }
    }

    private func withInteractions<Content: View>(_ content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: handleTap)
            .contextMenu { contextMenu }
            .onDrag {
                guard task.status.hasData else { return NSItemProvider() }
                return NSItemProvider(object: URL(fileURLWithPath: task.savePath) as NSURL)
            }
    }

    private func handleTap() {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) {
            // ⇧⌘ adds the run to what is already selected; plain ⇧ replaces it.
            vm.extendSelection(through: task.id, additive: mods.contains(.command))
        } else if mods.contains(.command) {
            vm.toggleSelection(task.id)
        } else {
            vm.selectOnly(task.id)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Theme.accent.opacity(listFocused ? 0.22 : 0.12) }
        if isHovered { return Theme.rowHover }
        return displayIndex.isMultiple(of: 2) ? Theme.rowAlt : Color.clear
    }

    /// A failure reads "Failed" in red with a glyph, not just a red dot, so it survives
    /// "Differentiate without colour".
    @ViewBuilder
    private var statusCell: some View {
        if case .failed(let error) = task.status {
            // The reason lives here, two lines deep, instead of squeezed under a narrow name.
            VStack(alignment: .leading, spacing: 1) {
                Label(L10n.t("Failed"), systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: Theme.TextSize.meta, weight: .semibold)
                    .foregroundStyle(Theme.red)
                    .lineLimit(1)
                Text(error.message)
                    .scaledFont(size: Theme.TextSize.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(task.statusColor).frame(width: 7, height: 7)
                    .a11yDecorative()
                Text(columns.showsSpeed
                     ? task.statusCompactText(queueRank: queueRank)
                     : task.statusFoldedText(speed: speed, queueRank: queueRank))
                    .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress = task.seedTargetProgress {
                    SeedTargetBar(progress: progress)
                }
            }
        }
    }

    /// "#" is the queue place. While the list is in queue order, hovering swaps it for a grip that
    /// drags the row (or the selection it belongs to) to a new place.
    @ViewBuilder
    private var indexCell: some View {
        if reorderable && isHovered {
            Image(systemName: "line.3.horizontal")
                .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .help(L10n.t("Drag to reorder the queue"))
                .onDrag {
                    let ids = vm.beginQueueDrag(from: task.id)
                    return NSItemProvider(object: ids.map(\.uuidString).joined(separator: "\n") as NSString)
                }
                .a11yDecorative()
        } else {
            Text("\(queueRank ?? displayIndex)")
                .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                .foregroundStyle(.secondary)
        }
    }

    /// The progress value plus what the compact status cell dropped: the ratio against its target
    /// while seeding, the place in line while queued.
    private var accessibilityValue: String {
        switch task.status {
        case .seeding: return A11y.sentence(task.accessibilityProgressValue, task.statusDetailText)
        case .queued: return A11y.sentence(task.accessibilityProgressValue, task.statusCompactText(queueRank: queueRank))
        default: return task.accessibilityProgressValue
        }
    }

    private var speedCell: some View {
        let text = SpeedCellText(speed: speed, isTorrent: task.kind == .torrent)
        return VStack(alignment: .trailing, spacing: 1) {
            if let down = text.down {
                Text(down)
                    .scaledFont(size: Theme.TextSize.body, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(Theme.green)
            }
            if let up = text.up {
                Text(up)
                    .scaledFont(size: text.down == nil ? 12.5 : 11, monospacedDigit: true)
                    .foregroundStyle(speed.up >= 1 ? Theme.teal : Color.secondary)
            }
        }
        .lineLimit(1)
    }

    private func primaryStateAction() {
        switch task.status {
        case .completed: task.isFileMissing ? vm.locateMissingFile(task) : vm.revealInFinder(task)
        case .failed: vm.retry(task.id)
        case .paused, .queued: vm.resume(task.id)
        default: vm.pause(task.id)
        }
    }

    private var nameCell: some View {
        HStack(spacing: 10) {
            StateButton(task: task, vm: vm)
            FileTypeIcon(type: task.fileType)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(task.compactDisplayName)
                        .scaledFont(size: Theme.TextSize.body, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    KindBadge(task: task)
                }
                // A failed row keeps its (red) track: how far it got before the reason in Status.
                MiniProgressBar(task: task)
                    .frame(maxWidth: 340)
                if !columns.showsSize, !task.compactSizeLine.isEmpty {
                    Text(task.compactSizeLine)
                        .scaledFont(size: Theme.TextSize.caption, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let summary = selectionSummary, summary.count > 1 {
            selectionMenu(summary)
        } else {
            singleRowMenu
        }
    }

    /// Right-clicking inside a multi-row selection commands the selection, not the row under the
    /// pointer. Only the commands that mean something in bulk appear; per-row ones (tags, note,
    /// Quick Look, per-task limits) stay on the single-row menu.
    /// Actions re-read `vm.selectedTasks` when they run: the summary only decides what is shown.
    @ViewBuilder
    private func selectionMenu(_ summary: SelectionSummary) -> some View {
        let count = summary.count
        if summary.canResume {
            Button(L10n.t("Resume %d Selected", count)) { vm.resumeSelected() }
        }
        if summary.canPause {
            Button(L10n.t("Pause %d Selected", count)) { vm.pauseSelected() }
        }
        if summary.canRetry {
            Button(L10n.t("Retry %d Selected", count)) { vm.retrySelected() }
        }
        Divider()
        Button(L10n.t("Copy %d Source Links", count)) {
            vm.copyToPasteboard(vm.selectedTasks.map(\.sourceLocator).joined(separator: "\n"))
        }
        if summary.canRename {
            Button(L10n.t("Rename %d Selected…", count)) { vm.promptForBatchRename(tasks: vm.selectedTasks) }
        }
        Divider()
        queueMenuItems
        Divider()
        Button(L10n.t("Remove %d from List", count), role: .destructive) {
            vm.removeSelected(deleteData: false)
        }
        Button(L10n.t("Remove %d and Move Files to Trash", count), role: .destructive) {
            vm.requestConfirm(
                title: L10n.t("Move the files of %d downloads to the Trash?", count),
                message: L10n.t("They are removed from the list. You can restore the files from the Trash."),
                confirmTitle: L10n.t("Move to Trash"),
                destructive: true
            ) { vm.removeSelected(deleteData: true) }
        }
    }

    @ViewBuilder
    private var singleRowMenu: some View {
        if task.isFileMissing {
            Button(L10n.t("Locate…")) { vm.locateMissingFile(task) }
            Button(L10n.t("Download Again")) { vm.downloadAgain(task) }
            Button(L10n.t("Remove from list"), role: .destructive) { vm.remove(task.id, deleteData: false) }
        } else {
            fullRowMenu
        }
    }

    @ViewBuilder
    private var fullRowMenu: some View {
        if task.status == .paused || task.status == .queued {

            Button(L10n.t("Resume")) { vm.resume(task.id) }
        } else if task.status.isActive {
            Button(L10n.t("Pause")) { vm.pause(task.id) }
        }
        if isFailed { Button(L10n.t("Retry")) { vm.retry(task.id) } }
        Button(L10n.t("Open folder")) { vm.revealInFinder(task) }
        if task.status == .completed || playableWhileDownloading {
            Button(L10n.t("Open in Player")) { vm.openFile(task) }
        }
        if task.isMediaFile, task.status.hasData,
           InAppPlayback.canPlay(URL(fileURLWithPath: task.primaryFilePath)) {
            Button(L10n.t("Play in Goel°")) { vm.playInApp(task) }
        }
        if task.status.hasData {
            Button(L10n.t("Quick Look")) { quickLook(URL(fileURLWithPath: task.savePath)) }
        }
        if task.status == .completed, task.isMediaFile {
            MediaMenuItems(task: task, vm: vm, center: vm.mediaJobs)
        }
        Button(L10n.t("Copy source link")) { vm.copyToPasteboard(task.sourceLocator) }
        if let prefix = context.streamLinkPrefix, RemoteStreamService.streamPlan(for: task) != nil {
            Button(L10n.t("Copy Stream Link")) {
                vm.copyToPasteboard("\(prefix)&id=\(task.id.uuidString)")
            }
        }
        Divider()
        // Toggles and inline pickers, not "✓ " prefixes: the menu then shows a real checkmark and
        // VoiceOver reads the item's state instead of "check mark Sequential Download".
        Menu(L10n.t("Speed Limit")) {
            limitPicker(current: task.speedLimitBytesPerSec) { vm.setTaskSpeedLimit($0, task: task.id) }
        }
        if task.kind == .torrent {
            Toggle(L10n.t("Sequential Download"), isOn: Binding(
                get: { task.sequentialDownload == true },
                set: { vm.setSequential($0, task: task.id) }))
            Menu(L10n.t("Upload Limit")) {
                limitPicker(current: task.uploadLimitBytesPerSec) { vm.setTaskUploadLimit($0, task: task.id) }
            }
            Menu(L10n.t("Seed Until Ratio")) {
                Picker(L10n.t("Seed Until Ratio"), selection: Binding(
                    get: { seedRatioChoice },
                    set: { choice in vm.setSeedRatioLimit(choice.ratio, task: task.id) })) {
                    ForEach(Self.seedRatioChoices, id: \.self) { choice in
                        Text(seedRatioLabel(choice.ratio)).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if task.status.isActive || task.status == .seeding || task.status == .paused {
                Button(L10n.t("Force Recheck")) { vm.forceRecheck(task.id) }
                Button(L10n.t("Re-announce to Trackers")) { vm.forceReannounce(task.id) }
            }
            if isMagnet {
                Button(L10n.t("Copy Magnet Link")) { vm.copyToPasteboard(task.sourceLocator) }
            }
        }
        Divider()
        if task.kind != .torrent, !task.status.isActive {
            Button(L10n.t("Rename…")) { vm.promptForRename(task: task) }
        }
        Button(task.allTags.isEmpty ? L10n.t("Add Tags…") : L10n.t("Edit Tags…")) { vm.promptForTags(task: task) }
        Button(task.note == nil ? L10n.t("Add Note…") : L10n.t("Edit Note…")) { vm.promptForNote(task: task) }
        if task.kind == .http {
            Button(L10n.t("Request Options…")) { vm.promptForRequestOptions(task: task) }
        }
        Button(task.label == nil ? L10n.t("Add Label…") : L10n.t("Edit Label…")) { vm.promptForLabel(task: task) }
        if task.status == .paused || task.status == .queued || task.status.isActive {
            Menu(L10n.t("Schedule Start")) {
                ForEach(ScheduledStartOption.presets) { preset in
                    Button(preset.label) { vm.setScheduledStart(preset.date(), task: task.id) }
                }
                if task.scheduledAt != nil {
                    Divider()
                    Button(L10n.t("Cancel Scheduled Start")) { vm.setScheduledStart(nil, task: task.id) }
                }
            }
        }
        Divider()
        queueMenuItems
        Divider()
        Button(L10n.t("Remove from list"), role: .destructive) { vm.remove(task.id, deleteData: false) }
        Button(L10n.t("Remove and Move File to Trash"), role: .destructive) {
            vm.requestConfirm(
                title: L10n.t("Move “%@” to the Trash?", task.compactDisplayName),
                message: L10n.t("It is removed from the list. You can restore the file from the Trash."),
                confirmTitle: L10n.t("Move to Trash"),
                destructive: true
            ) { vm.remove(task.id, deleteData: true) }
        }
    }

    /// Acts on the selection when the row is part of one, else on this row.
    @ViewBuilder
    private var queueMenuItems: some View {
        Button(L10n.t("Move to Top")) { vm.moveInQueue(vm.queueTargets(for: task.id), to: .top) }
        Button(L10n.t("Move to Bottom")) { vm.moveInQueue(vm.queueTargets(for: task.id), to: .bottom) }
    }

    private var isFailed: Bool { task.status.isFailed }

    private var playableWhileDownloading: Bool {
        task.kind == .torrent
            && task.sequentialDownload == true
            && task.fileType == .video
            && task.fractionCompleted > 0.02
    }

    private static let limitSteps: [Int64] = [1, 2, 5, 10, 25].map { $0 * 1_000_000 }

    /// nil and 0 both mean "no per-task cap", so both select Unlimited.
    @ViewBuilder
    private func limitPicker(current: Int64?, set: @escaping (Int64?) -> Void) -> some View {
        let selected: Int64 = current ?? 0
        Picker(L10n.t("Limit"), selection: Binding(get: { selected },
                                                   set: { set($0 == 0 ? nil : $0) })) {
            Text(L10n.t("Unlimited")).tag(Int64(0))
            ForEach(Self.limitSteps, id: \.self) { bytes in
                Text(L10n.t("%d MB/s", Int(bytes / 1_000_000))).tag(bytes)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// nil means the profile's global limit applies; an explicit 0 seeds forever regardless of it.
    struct SeedRatioChoice: Hashable {
        let ratio: Double?
    }

    private static let seedRatioChoices: [SeedRatioChoice] =
        [SeedRatioChoice(ratio: nil), SeedRatioChoice(ratio: 0)]
        + [0.5, 1.0, 1.5, 2.0, 3.0].map { SeedRatioChoice(ratio: $0) }

    /// The preset matching the task's ratio; a custom ratio set elsewhere matches none, so nothing is ticked.
    private var seedRatioChoice: SeedRatioChoice {
        guard let current = task.seedRatioLimit else { return SeedRatioChoice(ratio: nil) }
        return Self.seedRatioChoices.first { choice in
            choice.ratio.map { abs($0 - current) < 0.001 } ?? false
        } ?? SeedRatioChoice(ratio: current)
    }

    private func seedRatioLabel(_ ratio: Double?) -> String {
        switch ratio {
        case nil:
            return L10n.t("Profile default (%.1f×)", context.profileSeedRatio)
        case .some(let r) where r <= 0:
            return L10n.t("Seed indefinitely")
        case .some(let r):
            return String(format: "%.1f", r)
        }
    }

    private var failureTooltip: String? {
        guard case .failed(let error) = task.status else { return nil }
        return A11y.sentence(error.message, FailureAdvice.hint(for: error))
    }

    private var failureHint: String? {
        guard case .failed(let error) = task.status else { return nil }
        return FailureAdvice.hint(for: error)
    }

    private var isMagnet: Bool {
        if case .magnet = task.source { return true }
        return false
    }
}

/// The list's fixed column widths, scaled with the text size. A value, so rows compare it.
struct DownloadColumns: Equatable {
    var index: CGFloat = 30
    var size: CGFloat = 84
    var status: CGFloat = 150
    var added: CGFloat = 96
    var speed: CGFloat = 92
    var layout: Layout = .full

    /// Which columns fit. Narrower lists shed Added first, then fold Size under the name and
    /// Speed into Status, so the name never drops below ``minimumNameWidth``.
    enum Layout: Equatable {
        case full
        case noAdded
        case compact
    }

    static let minimumNameWidth: CGFloat = 180
    /// Each cell's 6 pt of padding on both sides.
    static let cellPadding: CGFloat = 12
    /// The row's 12 pt on both sides.
    static let rowPadding: CGFloat = 24

    init(scale: CGFloat = 1, listWidth: CGFloat? = nil) {
        let s = scale.isFinite && scale > 0 ? scale : 1
        index = (index * s).rounded()
        size = (size * s).rounded()
        status = (status * s).rounded()
        added = (added * s).rounded()
        speed = (speed * s).rounded()
        if let listWidth { layout = Self.layout(for: listWidth, columns: self) }
    }

    var showsSize: Bool { layout != .compact }
    var showsAdded: Bool { layout == .full }
    var showsSpeed: Bool { layout != .compact }

    /// The widest set whose fixed columns still leave the name its minimum. An unmeasured
    /// (zero) width keeps the full set rather than flashing the compact one on first layout.
    static func layout(for listWidth: CGFloat, columns: DownloadColumns) -> Layout {
        guard listWidth.isFinite, listWidth > 0 else { return .full }
        let chrome = rowPadding + cellPadding
        let base = columns.index + columns.status + 2 * cellPadding + chrome
        let full = base + columns.size + columns.added + columns.speed + 3 * cellPadding
        if listWidth >= full + minimumNameWidth { return .full }
        let noAdded = full - columns.added - cellPadding
        if listWidth >= noAdded + minimumNameWidth { return .noAdded }
        return .compact
    }
}

/// Owns the hover state so ``DownloadRow`` stays a pure value: only the hovered row's
/// equality changes when the pointer moves.
private struct HoverTrackingRow: View, Equatable {
    let row: DownloadRow
    @State private var hovered = false

    static func == (lhs: HoverTrackingRow, rhs: HoverTrackingRow) -> Bool { lhs.row == rhs.row }

    var body: some View {
        var shown = row
        shown.isHovered = hovered
        return shown
            .equatable()
            .onHover { hovered = $0 }
    }
}
