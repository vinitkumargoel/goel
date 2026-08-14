import SwiftUI
import AppKit
import QuickLook
import GoelCore

struct DownloadListView: View {
    @EnvironmentObject private var vm: AppViewModel

    @State private var quickLookItem: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.visibleTasks.isEmpty {
                emptyState
            } else {
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
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.selectNone() }
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
        .contentShape(Rectangle())
        .onTapGesture { vm.selectNone() }
        .quickLookPreview($quickLookItem)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
        .accessibilityLabel(L10n.t("Download queue"))
        .accessibilityHint(L10n.t("Use the up and down arrow keys to move through downloads, shift with an arrow to extend the selection, command A to select all, space to preview, return to open."))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let extending = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow, .downArrow:
            guard !press.modifiers.contains(.command) else { return .ignored }
            return moved(vm.moveSelection(by: press.key == .downArrow ? 1 : -1, extending: extending))
        case .home, .end:
            return moved(vm.selectEdge(last: press.key == .end, extending: extending))
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

    private func moved(_ didMove: Bool) -> KeyPress.Result {
        guard didMove else { return .ignored }
        if !vm.detailPanelVisible { vm.detailPanelVisible = true }
        return .handled
    }

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
                Text(L10n.t(title))
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
        .a11yButton(spokenHeader(title),
                    hint: isSortKey
                        ? L10n.t("Currently sorting %@. Activate to reverse.",
                                 vm.sortAscending ? L10n.t("ascending") : L10n.t("descending"))
                        : L10n.t("Activate to sort by this column."))
        .accessibilityValue(isSortKey
                            ? (vm.sortAscending ? L10n.t("Sorted ascending") : L10n.t("Sorted descending"))
                            : L10n.t("Not sorted"))
    }

    private func spokenHeader(_ title: String) -> String {
        switch title {
        case "#": return L10n.t("Row number")
        case "↓ Speed": return L10n.t("Download speed")
        case "↑ Speed": return L10n.t("Upload speed")
        default: return L10n.t(title)
        }
    }

    private var emptyState: some View {
        EmptyStateView(systemImage: "tray", title: L10n.t("No downloads match"),
                       subtitle: L10n.t("Try a different filter or search term."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `vm` is deliberately non-observed: observing it rebuilds every row on every task's progress tick.
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
        // Label is identity only: folding in the ticking percent makes VoiceOver re-speak the row every second.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(task.name,
                                          task.accessibilityKindName,
                                          task.accessibilityStatusName))
        .accessibilityValue(task.accessibilityProgressValue)
        .accessibilityAddTraits(isSelected
                                ? [.isButton, .isSelected, .updatesFrequently]
                                : [.isButton, .updatesFrequently])
        .accessibilityHint(L10n.t("Select to show details."))
        .accessibilityAction(named: Text(L10n.t(task.accessibilityStateActionName)), primaryStateAction)
        .accessibilityAction(named: Text(L10n.t("Show in Finder"))) { vm.revealInFinder(task) }
        .accessibilityAction(named: Text(L10n.t("Copy source link"))) { vm.copyToPasteboard(task.sourceLocator) }
        .accessibilityAction(named: Text(L10n.t("Remove from list"))) { vm.remove(task.id, deleteData: false) }
        .contentShape(Rectangle())
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            if mods.contains(.shift) {
                // ⇧⌘ adds the run to what is already selected; plain ⇧ replaces it.
                vm.extendSelection(through: task.id, additive: mods.contains(.command))
            } else if mods.contains(.command) {
                vm.toggleSelection(task.id)
            } else {
                vm.selectOnly(task.id)
            }
            if !vm.detailPanelVisible { vm.detailPanelVisible = true }
        }
        .contextMenu { contextMenu }
        .onDrag {
            guard task.status.hasData else { return NSItemProvider() }
            return NSItemProvider(object: URL(fileURLWithPath: task.savePath) as NSURL)
        }
    }

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
        if vm.actsOnSelection(task.id) { selectionMenu } else { singleRowMenu }
    }

    /// Right-clicking inside a multi-row selection commands the selection, not the row under the
    /// pointer. Only the commands that mean something in bulk appear; per-row ones (tags, note,
    /// Quick Look, per-task limits) stay on the single-row menu.
    @ViewBuilder
    private var selectionMenu: some View {
        let targets = vm.selectedTasks
        let count = targets.count
        if targets.contains(where: { $0.status == .paused || $0.status == .queued }) {
            Button(L10n.t("Resume %d Selected", count)) { vm.resumeSelected() }
        }
        if targets.contains(where: { $0.status.isActive }) {
            Button(L10n.t("Pause %d Selected", count)) { vm.pauseSelected() }
        }
        if targets.contains(where: { if case .failed = $0.status { return true } else { return false } }) {
            Button(L10n.t("Retry %d Selected", count)) { vm.retrySelected() }
        }
        Divider()
        Button(L10n.t("Copy %d Source Links", count)) {
            vm.copyToPasteboard(targets.map(\.sourceLocator).joined(separator: "\n"))
        }
        if targets.allSatisfy({ $0.kind != .torrent && !$0.status.isActive }) {
            Button(L10n.t("Rename %d Selected…", count)) { vm.promptForBatchRename(tasks: targets) }
        }
        Divider()
        Button(L10n.t("Remove %d from List", count), role: .destructive) {
            vm.removeSelected(deleteData: false)
        }
        Button(L10n.t("Remove %d with Data", count), role: .destructive) {
            vm.requestConfirm(
                title: L10n.t("Delete downloaded files for %d items?", count),
                message: L10n.t("This permanently deletes the files from disk and can’t be undone."),
                confirmTitle: L10n.t("Delete Files"),
                destructive: true
            ) { vm.removeSelected(deleteData: true) }
        }
    }

    @ViewBuilder
    private var singleRowMenu: some View {
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
            if let reason = vm.ffmpegUnavailableReason {
                Button(L10n.t("Convert To…")) { vm.toastNow(reason) }
                Button(L10n.t("Extract Audio…")) { vm.toastNow(reason) }
            } else {
                MediaMenuItems(task: task, vm: vm, center: vm.mediaJobs)
            }
        }
        Button(L10n.t("Copy source link")) { vm.copyToPasteboard(task.sourceLocator) }
        if vm.settings.remoteAccessEnabled, !vm.settings.remoteToken.isEmpty,
           RemoteStreamService.streamPlan(for: task) != nil {
            Button(L10n.t("Copy Stream Link")) {
                // With `remoteTLSEnabled` the socket speaks only TLS; a hardcoded http:// link cannot connect.
                let scheme = vm.settings.remoteTLSEnabled ? "https" : "http"
                vm.copyToPasteboard("\(scheme)://127.0.0.1:\(vm.settings.remotePort)/stream?id=\(task.id.uuidString)&token=\(vm.settings.remoteToken)")
            }
        }
        Divider()
        Menu(L10n.t("Speed Limit")) {
            Button(limitLabel(nil)) { vm.setTaskSpeedLimit(nil, task: task.id) }
            ForEach([1, 2, 5, 10, 25], id: \.self) { mb in
                Button(limitLabel(Int64(mb) * 1_000_000)) {
                    vm.setTaskSpeedLimit(Int64(mb) * 1_000_000, task: task.id)
                }
            }
        }
        if task.kind == .torrent {
            Button(task.sequentialDownload == true
                   ? L10n.t("✓ Sequential Download") : L10n.t("Sequential Download")) {
                vm.setSequential(!(task.sequentialDownload == true), task: task.id)
            }
            Menu(L10n.t("Upload Limit")) {
                Button(uploadLimitLabel(nil)) { vm.setTaskUploadLimit(nil, task: task.id) }
                ForEach([1, 2, 5, 10, 25], id: \.self) { mb in
                    Button(uploadLimitLabel(Int64(mb) * 1_000_000)) {
                        vm.setTaskUploadLimit(Int64(mb) * 1_000_000, task: task.id)
                    }
                }
            }
            Menu(L10n.t("Seed Until Ratio")) {
                Button(seedRatioLabel(nil)) { vm.setSeedRatioLimit(nil, task: task.id) }
                Button(seedRatioLabel(0)) { vm.setSeedRatioLimit(0, task: task.id) }
                ForEach([0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) { r in
                    Button(seedRatioLabel(r)) { vm.setSeedRatioLimit(r, task: task.id) }
                }
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
        Button(L10n.t("Remove from list"), role: .destructive) { vm.remove(task.id, deleteData: false) }
        Button(L10n.t("Remove with data"), role: .destructive) {
            vm.requestConfirm(
                title: L10n.t("Delete downloaded files for “%@”?", task.name),
                message: L10n.t("This permanently deletes the file from disk and can’t be undone."),
                confirmTitle: L10n.t("Delete Files"),
                destructive: true
            ) { vm.remove(task.id, deleteData: true) }
        }
    }

    private var isFailed: Bool {
        if case .failed = task.status { return true }
        return false
    }

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
        let name = bytesPerSec.map { "\($0 / 1_000_000) MB/s" } ?? L10n.t("Unlimited")
        return isActive ? "✓ \(name)" : name
    }

    private func uploadLimitLabel(_ bytesPerSec: Int64?) -> String {
        let current = task.uploadLimitBytesPerSec
        let isActive = bytesPerSec == nil
            ? (current == nil || current == 0)
            : current == bytesPerSec
        let name = bytesPerSec.map { "\($0 / 1_000_000) MB/s" } ?? L10n.t("Unlimited")
        return isActive ? "✓ \(name)" : name
    }

    /// nil means the profile's global limit applies; an explicit 0 seeds forever regardless of it.
    private func seedRatioLabel(_ ratio: Double?) -> String {
        let current = task.seedRatioLimit
        let isActive = ratio == nil
            ? (current == nil)
            : (current.map { abs($0 - ratio!) < 0.001 } ?? false)
        let name: String
        switch ratio {
        case nil:
            name = L10n.t("Profile default (%.1f×)", vm.settings.effectiveProfile.seedRatioLimit)
        case .some(let r) where r <= 0:
            name = L10n.t("Seed indefinitely")
        case .some(let r):
            name = String(format: "%.1f", r)
        }
        return isActive ? "✓ \(name)" : name
    }

    private var isMagnet: Bool {
        if case .magnet = task.source { return true }
        return false
    }
}

/// Observes ``MediaJobCenter`` directly: a nested observable's changes don't propagate through the outer one.
private struct MediaMenuItems: View {

    let task: DownloadTask
    let vm: AppViewModel
    @ObservedObject var center: MediaJobCenter

    private var input: URL { URL(fileURLWithPath: task.savePath) }

    var body: some View {
        let live = center.liveJobs(input: input)
        ForEach(live) { job in
            Button(L10n.t("Cancel %@", L10n.midSentence(job.kind.activeTitle))) { center.cancel(job.id) }
        }
        if !live.isEmpty { Divider() }
        Menu(L10n.t("Convert To")) {
            ForEach(MediaContainer.convertTargets, id: \.self) { ext in
                Button(label(for: ext)) { vm.convertFile(task: task, toExtension: ext) }
                    .disabled(center.liveJob(input: input, outputExtension: ext) != nil)
            }
        }
        Menu(L10n.t("Extract Audio")) {
            ForEach(AudioExtractionFormat.allCases, id: \.self) { format in
                Button(format.displayName) { vm.extractAudio(task: task, format: format) }
                    .disabled(center.liveJob(input: input, outputExtension: format.rawValue) != nil)
            }
        }
    }

    private func label(for ext: String) -> String {
        let source = input.pathExtension
        guard !source.isEmpty,
              MediaContainer.likelyStreamCopy(from: source, to: ext) else {
            return ext.uppercased()
        }
        return L10n.t("%@ — copy, instant", ext.uppercased())
    }
}
