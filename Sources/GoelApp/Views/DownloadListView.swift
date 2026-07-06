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
                            Divider()
                        }
                        // Clicking the empty area below the rows clears the
                        // selection, so the detail panel slides away.
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.selectNone() }
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
    var quickLook: (URL) -> Void = { _ in }

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

            Text(vm.displaySpeed(for: task).down.speedString)
                .frame(width: 84, alignment: .trailing)
                .padding(.horizontal, 6)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(vm.displaySpeed(for: task).down > 0 ? Theme.green : Color.secondary)
                .monospacedDigit()

            Text(vm.displaySpeed(for: task).up.speedString)
                .frame(width: 84, alignment: .trailing)
                .padding(.horizontal, 6)
                .font(.system(size: 12.5))
                .foregroundStyle(vm.displaySpeed(for: task).up > 0 ? Theme.teal : Color.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .background(isSelected ? Theme.accent.opacity(0.22) : (displayIndex.isMultiple(of: 2) ? Theme.rowAlt : Color.clear))
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
        if task.status == .completed || playableWhileDownloading {
            Button("Open in Player") { vm.openFile(task) }
        }
        if task.isMediaFile, task.status.hasData {
            Button("Play in Goel°") { vm.playInApp(task) }
        }
        if task.status.hasData {
            Button("Quick Look") { quickLook(URL(fileURLWithPath: task.savePath)) }
        }
        if task.status == .completed, task.isMediaFile, vm.ffmpegAvailable {
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
        Button("Copy source link") { vm.copyToPasteboard(task.sourceLocator) }
        if vm.settings.remoteAccessEnabled, !vm.settings.remoteToken.isEmpty,
           RemoteControlServer.streamPlan(for: task) != nil {
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
