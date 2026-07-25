import SwiftUI
import AppKit
import QuickLook
import GoelCore

/// The center list: a sortable header and selectable rows with inline progress,
/// type badge, and per-row state button. Columns: #, Name, Size, Status, Added,
/// ↓ Speed, ↑ Speed.
struct DownloadListView: View {
    @EnvironmentObject private var vm: AppViewModel

    /// The file being previewed with Quick Look (spacebar / context menu).
    @State private var quickLookItem: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.visibleTasks.isEmpty {
                emptyState
            } else {
                // `ScrollViewReader` so keyboard navigation can bring the newly
                // selected row into view — arrow keys that move an invisible
                // selection are worse than no arrow keys at all.
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.visibleTasks.enumerated()), id: \.element.id) { index, task in
                            DownloadRow(
                                task: task,
                                displayIndex: index + 1,
                                isSelected: vm.isSelected(task.id),
                                vm: vm,
                                quickLook: { quickLookItem = $0 }
                            )
                            .id(task.id)
                            Divider()
                        }
                        // Clicking the empty area below the rows clears the
                        // selection, so the detail panel slides away.
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.selectNone() }
                            // A deselect target with no visible content; there is
                            // a keyboard/menu route to the same result.
                            .a11yDecorative()
                    }
                }
                .onChange(of: vm.selectedTask?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        // A click anywhere in the list background (not on a row) deselects.
        .contentShape(Rectangle())
        .onTapGesture { vm.selectNone() }
        .quickLookPreview($quickLookItem)
        // Spacebar previews the primary selection, Finder-style.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let task = vm.selectedTask, task.status.hasData else { return .ignored }
            quickLookItem = URL(fileURLWithPath: task.savePath)
            return .handled
        }
        // Keyboard navigation of the queue. Previously the list could only be
        // driven by the mouse: it took focus and handled the spacebar, but the
        // arrow keys did nothing, so a keyboard-only user could never *reach* a
        // row to preview it. Selection is the app's primary interaction — it
        // drives the detail panel — so it has to be reachable without a pointer.
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        // Return performs the row's primary action, matching a double-click.
        .onKeyPress(.return) {
            guard let task = vm.selectedTask else { return .ignored }
            if task.status == .completed { vm.openFile(task) } else { vm.revealInFinder(task) }
            return .handled
        }
        .accessibilityLabel("Download queue")
        .accessibilityHint("Use the up and down arrow keys to move through downloads, space to preview, return to open.")
    }

    /// Move the selection `offset` rows through the *visible* (filtered, sorted)
    /// order, starting at the top when nothing is selected yet. Clamped rather
    /// than wrapping, so holding an arrow key parks at an end instead of cycling.
    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let tasks = vm.visibleTasks
        guard !tasks.isEmpty else { return .ignored }
        let current = vm.selectedTask.flatMap { sel in tasks.firstIndex { $0.id == sel.id } }
        let next = current.map { min(max(0, $0 + offset), tasks.count - 1) }
                   ?? (offset > 0 ? 0 : tasks.count - 1)
        vm.selectOnly(tasks[next].id)
        if !vm.detailPanelVisible { vm.detailPanelVisible = true }
        return .handled
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
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func headerCol(_ title: String, _ key: SortKey, width: CGFloat?, alignment: Alignment) -> some View {
        let isSortKey = vm.sortKey == key
        Button {
            vm.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                if isSortKey {
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
        // Sort direction is signalled only by a 8pt chevron and its accent tint —
        // both invisible to a screen reader and to anyone who can't distinguish
        // the tint. State it, and spell out the arrow-glyph headings ("↓ Speed").
        .a11yButton(spokenHeader(title),
                    hint: isSortKey
                        ? "Currently sorting \(vm.sortAscending ? "ascending" : "descending"). Activate to reverse."
                        : "Activate to sort by this column.")
        .accessibilityValue(isSortKey ? (vm.sortAscending ? "Sorted ascending" : "Sorted descending") : "Not sorted")
    }

    /// Column headings as words. The visible strings lean on typography the ear
    /// can't hear: "#" is a symbol, "↓ Speed" / "↑ Speed" are arrows.
    private func spokenHeader(_ title: String) -> String {
        switch title {
        case "#": return "Row number"
        case "↓ Speed": return "Download speed"
        case "↑ Speed": return "Upload speed"
        default: return title
        }
    }

    /// Shown when the filter/search matched nothing — *not* on first run.
    ///
    /// `RootView` renders `DownloadsEmptyState` whenever the queue itself is
    /// empty, so this no longer has to double as the welcome screen and can stay
    /// specific to "you filtered everything away". Keep the copy narrow: widening
    /// it back to a generic "no downloads" would make the first-run affordances
    /// unreachable behind a filter.
    private var emptyState: some View {
        EmptyStateView(systemImage: "tray", title: "No downloads match",
                       subtitle: "Try a different filter or search term.")
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
    var quickLook: (URL) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            Text("\(displayIndex)")
                .scaledFont(size: 11.5, monospacedDigit: true)
                .foregroundStyle(.tertiary)
                .frame(width: 30)
                .padding(.horizontal, 6)

            nameCell
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            Text(task.totalBytes?.byteString ?? "—")
                .scaledFont(size: 12.5, monospacedDigit: true)
                .frame(width: 84, alignment: .trailing)
                .padding(.horizontal, 6)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                // The dot repeats the status word beside it in colour form —
                // which is exactly the colour-alone signal WCAG 1.4.1 warns
                // about, and the text is the accessible equivalent.
                Circle().fill(task.statusColor).frame(width: 7, height: 7)
                    .a11yDecorative()
                Text(task.statusDetailText)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
            .padding(.horizontal, 6)

            Text(task.addedString)
                .scaledFont(size: 11.5)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
                .padding(.horizontal, 6)

            Text(vm.displaySpeed(for: task).down.speedString)
                .frame(width: 84, alignment: .trailing)
                .padding(.horizontal, 6)
                .scaledFont(size: 12.5, weight: .medium, monospacedDigit: true)
                .foregroundStyle(vm.displaySpeed(for: task).down > 0 ? Theme.green : Color.secondary)

            Text(vm.displaySpeed(for: task).up.speedString)
                .frame(width: 84, alignment: .trailing)
                .padding(.horizontal, 6)
                .scaledFont(size: 12.5, monospacedDigit: true)
                .foregroundStyle(vm.displaySpeed(for: task).up > 0 ? Theme.teal : Color.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .background(isSelected ? Theme.accent.opacity(0.22) : (displayIndex.isMultiple(of: 2) ? Theme.rowAlt : Color.clear))
        // ── One row, one element ────────────────────────────────────────────
        // Left alone, this row exposes eight separate elements — index, name,
        // kind badge, progress bar, size, status dot, date, and two speeds — so
        // reading a single download costs nine swipes and arrives as fragments
        // with no stated relationship. Collapsing to one element with a spoken
        // label and a separately-refreshable value makes it read the way it
        // looks: as one download.
        //
        // The inline state button is folded in as an accessibility *action*
        // rather than left as a child. Keeping it as a child would re-split the
        // row, and the same command is also on the context menu — which is where
        // the rest of these actions come from, so the action rotor ends up a
        // faithful subset of what a right-click offers.
        //
        // The label is the row's *identity* — name, transport, state — and
        // nothing that ticks. VoiceOver re-reads a whole element when its label
        // changes, so folding the live percent and ETA into the label (which
        // `accessibilityRowLabel` does) made a focused row re-speak all fifteen
        // words about once a second, and say the percent and estimate twice
        // because the value already carries them. The moving numbers belong in
        // `accessibilityProgressValue`, which `.updatesFrequently` lets a screen
        // reader re-read on its own without disturbing the label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(task.name,
                                          task.accessibilityKindName,
                                          task.accessibilityStatusName))
        .accessibilityValue(task.accessibilityProgressValue)
        .accessibilityAddTraits(isSelected
                                ? [.isButton, .isSelected, .updatesFrequently]
                                : [.isButton, .updatesFrequently])
        .accessibilityHint("Select to show details.")
        .accessibilityAction(named: Text(task.accessibilityStateActionName), primaryStateAction)
        .accessibilityAction(named: Text("Show in Finder")) { vm.revealInFinder(task) }
        .accessibilityAction(named: Text("Copy source link")) { vm.copyToPasteboard(task.sourceLocator) }
        .accessibilityAction(named: Text("Remove from list")) { vm.remove(task.id, deleteData: false) }
        .contentShape(Rectangle())
        .onTapGesture {
            // ⌘-click extends the selection; a plain click replaces it.
            if NSEvent.modifierFlags.contains(.command) {
                vm.toggleSelection(task.id)
            } else {
                vm.selectOnly(task.id)
            }
            if !vm.detailPanelVisible { vm.detailPanelVisible = true }
        }
        .contextMenu { contextMenu }
        // A finished download can be dragged straight out to Finder/other apps.
        .onDrag {
            guard task.status.hasData else { return NSItemProvider() }
            return NSItemProvider(object: URL(fileURLWithPath: task.savePath) as NSURL)
        }
    }

    /// The same branch ``StateButton`` takes, reused so the row's rotor action
    /// and the visible button can never disagree about what the state means.
    private func primaryStateAction() {
        switch task.status {
        case .completed: vm.revealInFinder(task)
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
                    Text(task.name)
                        .scaledFont(size: 12.5, weight: .medium)
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
        if task.status == .completed || playableWhileDownloading {
            Button("Open in Player") { vm.openFile(task) }
        }
        if task.isMediaFile, task.status.hasData {
            Button("Play in Goel°") { vm.playInApp(task) }
        }
        if task.status.hasData {
            Button("Quick Look") { quickLook(URL(fileURLWithPath: task.savePath)) }
        }
        // The capability stays VISIBLE when ffmpeg is missing and says why.
        // Hiding it made "Convert" indistinguishable from a feature Goel° does
        // not have, which is the user-visible half of the missing-ffmpeg bug.
        if task.status == .completed, task.isMediaFile {
            if let reason = vm.ffmpegUnavailableReason {
                Button("Convert To…") { vm.toastNow(reason) }
                Button("Extract Audio…") { vm.toastNow(reason) }
            } else {
                Menu("Convert To") {
                    ForEach(["mp4", "mkv", "webm", "mov"], id: \.self) { ext in
                        Button(ext.uppercased()) { vm.convertFile(task: task, toExtension: ext) }
                    }
                }
                Menu("Extract Audio") {
                    ForEach(FFmpegService.AudioFormat.allCases, id: \.self) { fmt in
                        Button(fmt.rawValue.uppercased()) { vm.extractAudio(task: task, format: fmt) }
                    }
                }
            }
        }
        Button("Copy source link") { vm.copyToPasteboard(task.sourceLocator) }
        if vm.settings.remoteAccessEnabled, !vm.settings.remoteToken.isEmpty,
           RemoteStreamService.streamPlan(for: task) != nil {
            Button("Copy Stream Link") {
                vm.copyToPasteboard("http://127.0.0.1:\(vm.settings.remotePort)/stream?id=\(task.id.uuidString)&token=\(vm.settings.remoteToken)")
            }
        }
        Divider()
        Menu("Speed Limit") {
            Button(limitLabel(nil)) { vm.setTaskSpeedLimit(nil, task: task.id) }
            ForEach([1, 2, 5, 10, 25], id: \.self) { mb in
                Button(limitLabel(Int64(mb) * 1_000_000)) {
                    vm.setTaskSpeedLimit(Int64(mb) * 1_000_000, task: task.id)
                }
            }
        }
        if task.kind == .torrent {
            Button(task.sequentialDownload == true
                   ? "✓ Sequential Download" : "Sequential Download") {
                vm.setSequential(!(task.sequentialDownload == true), task: task.id)
            }
            Menu("Upload Limit") {
                Button(uploadLimitLabel(nil)) { vm.setTaskUploadLimit(nil, task: task.id) }
                ForEach([1, 2, 5, 10, 25], id: \.self) { mb in
                    Button(uploadLimitLabel(Int64(mb) * 1_000_000)) {
                        vm.setTaskUploadLimit(Int64(mb) * 1_000_000, task: task.id)
                    }
                }
            }
            Menu("Seed Until Ratio") {
                Button(seedRatioLabel(nil)) { vm.setSeedRatioLimit(nil, task: task.id) }
                ForEach([0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) { r in
                    Button(seedRatioLabel(r)) { vm.setSeedRatioLimit(r, task: task.id) }
                }
            }
            if task.status.isActive || task.status == .seeding || task.status == .paused {
                Button("Force Recheck") { vm.forceRecheck(task.id) }
                Button("Re-announce to Trackers") { vm.forceReannounce(task.id) }
            }
            if isMagnet {
                Button("Copy Magnet Link") { vm.copyToPasteboard(task.sourceLocator) }
            }
        }
        Divider()
        if task.kind != .torrent, !task.status.isActive {
            if vm.selection.count > 1, vm.selection.contains(task.id) {
                Button("Rename \(vm.selection.count) Selected…") {
                    vm.promptForBatchRename(tasks: vm.tasks.filter { vm.selection.contains($0.id) })
                }
            } else {
                Button("Rename…") { vm.promptForRename(task: task) }
            }
        }
        Button(task.allTags.isEmpty ? "Add Tags…" : "Edit Tags…") { vm.promptForTags(task: task) }
        Button(task.note == nil ? "Add Note…" : "Edit Note…") { vm.promptForNote(task: task) }
        if task.kind == .http {
            Button("Request Options…") { vm.promptForRequestOptions(task: task) }
        }
        Button(task.label == nil ? "Add Label…" : "Edit Label…") { vm.promptForLabel(task: task) }
        if task.status == .paused || task.status == .queued || task.status.isActive {
            Menu("Schedule Start") {
                ForEach(ScheduledStartOption.presets) { preset in
                    Button(preset.label) { vm.setScheduledStart(preset.date(), task: task.id) }
                }
                if task.scheduledAt != nil {
                    Divider()
                    Button("Cancel Scheduled Start") { vm.setScheduledStart(nil, task: task.id) }
                }
            }
        }
        Divider()
        Button("Remove from list", role: .destructive) { vm.remove(task.id, deleteData: false) }
        Button("Remove with data", role: .destructive) {
            vm.requestConfirm(
                title: "Delete downloaded files for “\(task.name)”?",
                message: "This permanently deletes the file from disk and can’t be undone.",
                confirmTitle: "Delete Files",
                destructive: true
            ) { vm.remove(task.id, deleteData: true) }
        }
    }

    private var isFailed: Bool {
        if case .failed = task.status { return true }
        return false
    }

    /// A sequential torrent's video becomes watchable mid-download; offer the
    /// player once a meaningful chunk exists.
    private var playableWhileDownloading: Bool {
        task.kind == .torrent
            && task.sequentialDownload == true
            && task.fileType == .video
            && task.fractionCompleted > 0.02
    }

    private func limitLabel(_ bytesPerSec: Int64?) -> String {
        let current = task.speedLimitBytesPerSec
        let isActive = bytesPerSec == nil
            ? (current == nil || current == 0)
            : current == bytesPerSec
        let name = bytesPerSec.map { "\($0 / 1_000_000) MB/s" } ?? "Unlimited"
        return isActive ? "✓ \(name)" : name
    }

    private func uploadLimitLabel(_ bytesPerSec: Int64?) -> String {
        let current = task.uploadLimitBytesPerSec
        let isActive = bytesPerSec == nil
            ? (current == nil || current == 0)
            : current == bytesPerSec
        let name = bytesPerSec.map { "\($0 / 1_000_000) MB/s" } ?? "Unlimited"
        return isActive ? "✓ \(name)" : name
    }

    private func seedRatioLabel(_ ratio: Double?) -> String {
        let current = task.seedRatioLimit
        let isActive = ratio == nil
            ? (current == nil)
            : (current.map { abs($0 - ratio!) < 0.001 } ?? false)
        let name = ratio.map { String(format: "%.1f", $0) } ?? "Unlimited"
        return isActive ? "✓ \(name)" : name
    }

    private var isMagnet: Bool {
        if case .magnet = task.source { return true }
        return false
    }
}
