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
        .onKeyPress(.space) {
            guard let task = vm.selectedTask, task.status.hasData else { return .ignored }
            quickLookItem = URL(fileURLWithPath: task.savePath)
            return .handled
        }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.return) {
            guard let task = vm.selectedTask else { return .ignored }
            if task.status == .completed { vm.openFile(task) } else { vm.revealInFinder(task) }
            return .handled
        }
        .accessibilityLabel("Download queue")
        .accessibilityHint("Use the up and down arrow keys to move through downloads, space to preview, return to open.")
    }

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
        .a11yButton(spokenHeader(title),
                    hint: isSortKey
                        ? "Currently sorting \(vm.sortAscending ? "ascending" : "descending"). Activate to reverse."
                        : "Activate to sort by this column.")
        .accessibilityValue(isSortKey ? (vm.sortAscending ? "Sorted ascending" : "Sorted descending") : "Not sorted")
    }

    private func spokenHeader(_ title: String) -> String {
        switch title {
        case "#": return "Row number"
        case "↓ Speed": return "Download speed"
        case "↑ Speed": return "Upload speed"
        default: return title
        }
    }

    private var emptyState: some View {
        EmptyStateView(systemImage: "tray", title: "No downloads match",
                       subtitle: "Try a different filter or search term.")
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
        .accessibilityHint("Select to show details.")
        .accessibilityAction(named: Text(task.accessibilityStateActionName), primaryStateAction)
        .accessibilityAction(named: Text("Show in Finder")) { vm.revealInFinder(task) }
        .accessibilityAction(named: Text("Copy source link")) { vm.copyToPasteboard(task.sourceLocator) }
        .accessibilityAction(named: Text("Remove from list")) { vm.remove(task.id, deleteData: false) }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
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
        if task.status == .completed, task.isMediaFile {
            if let reason = vm.ffmpegUnavailableReason {
                Button("Convert To…") { vm.toastNow(reason) }
                Button("Extract Audio…") { vm.toastNow(reason) }
            } else {
                MediaMenuItems(task: task, vm: vm, center: vm.mediaJobs)
            }
        }
        Button("Copy source link") { vm.copyToPasteboard(task.sourceLocator) }
        if vm.settings.remoteAccessEnabled, !vm.settings.remoteToken.isEmpty,
           RemoteStreamService.streamPlan(for: task) != nil {
            Button("Copy Stream Link") {
                // With `remoteTLSEnabled` the socket speaks only TLS; a hardcoded http:// link cannot connect.
                let scheme = vm.settings.remoteTLSEnabled ? "https" : "http"
                vm.copyToPasteboard("\(scheme)://127.0.0.1:\(vm.settings.remotePort)/stream?id=\(task.id.uuidString)&token=\(vm.settings.remoteToken)")
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
                Button(seedRatioLabel(0)) { vm.setSeedRatioLimit(0, task: task.id) }
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

    /// nil means the profile's global limit applies; an explicit 0 seeds forever regardless of it.
    private func seedRatioLabel(_ ratio: Double?) -> String {
        let current = task.seedRatioLimit
        let isActive = ratio == nil
            ? (current == nil)
            : (current.map { abs($0 - ratio!) < 0.001 } ?? false)
        let name: String
        switch ratio {
        case nil:
            name = String(format: "Profile default (%.1f×)", vm.settings.effectiveProfile.seedRatioLimit)
        case .some(let r) where r <= 0:
            name = "Seed indefinitely"
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
            Button("Cancel \(job.kind.activeTitle.lowercased())") { center.cancel(job.id) }
        }
        if !live.isEmpty { Divider() }
        Menu("Convert To") {
            ForEach(MediaContainer.convertTargets, id: \.self) { ext in
                Button(label(for: ext)) { vm.convertFile(task: task, toExtension: ext) }
                    .disabled(center.liveJob(input: input, outputExtension: ext) != nil)
            }
        }
        Menu("Extract Audio") {
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
        return "\(ext.uppercased()) — copy, instant"
    }
}
