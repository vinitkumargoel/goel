import SwiftUI
import GoelCore

/// App-wide values a row or card reads, captured once per list body instead of per item. The
/// language and day are ambient (`L10n.currentLanguage`, "today"): without them here an
/// unchanged row kept its old words or "Today" label.
struct DownloadItemContext: Equatable {
    var streamLinkPrefix: String?
    var profileSeedRatio: Double
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
struct DownloadSelectionSummary: Equatable {
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

/// The row and card context menu.
struct DownloadContextMenu: View {
    let task: DownloadTask
    let summary: DownloadSelectionSummary?
    let context: DownloadItemContext
    let vm: AppViewModel
    let quickLook: QuickLookAction

    var body: some View {
        DownloadMenuContent(nodes: DownloadMenuBuilder(task: task, context: context, vm: vm,
                                                       quickLook: quickLook).nodes(summary: summary))
    }
}

/// Builds the context menu as nodes. Right-clicking inside a multi-row selection commands the
/// selection, not the item under the pointer; a single item gets the full menu.
@MainActor
struct DownloadMenuBuilder {
    let task: DownloadTask
    let context: DownloadItemContext
    let vm: AppViewModel
    let quickLook: QuickLookAction

    func nodes(summary: DownloadSelectionSummary?) -> [DownloadMenuNode] {
        if let summary, summary.count > 1 { return selectionNodes(summary) }
        if task.isFileMissing {
            return [
                .button(L10n.t("Locate…"), symbol: "magnifyingglass") { vm.locateMissingFile(task) },
                .button(L10n.t("Download Again"), symbol: "arrow.down.circle") { vm.downloadAgain(task) },
                .button(L10n.t("Remove from List"), role: .destructive) { vm.remove(task.id, deleteData: false) },
            ]
        }
        return fullNodes()
    }

    /// Only the commands that mean something in bulk; per-row ones (tags, note, Quick Look,
    /// per-task limits) stay on the single-row menu. Actions re-read `vm.selectedTasks` when
    /// they run: the summary only decides what is shown.
    func selectionNodes(_ summary: DownloadSelectionSummary) -> [DownloadMenuNode] {
        let count = summary.count
        let vm = self.vm
        var nodes: [DownloadMenuNode] = []
        if summary.canResume {
            nodes.append(.button(L10n.t("Resume %d Selected", count), symbol: "play") { vm.resumeSelected() })
        }
        if summary.canPause {
            nodes.append(.button(L10n.t("Pause %d Selected", count), symbol: "pause") { vm.pauseSelected() })
        }
        if summary.canRetry {
            nodes.append(.button(L10n.t("Retry %d Selected", count), symbol: "arrow.clockwise") { vm.retrySelected() })
        }
        nodes.append(.divider)
        nodes.append(.button(L10n.t("Copy %d Source Links", count), symbol: "link") {
            vm.copyToPasteboard(vm.selectedTasks.map(\.sourceLocator).joined(separator: "\n"))
        })
        if summary.canRename {
            nodes.append(.button(L10n.t("Rename %d Selected…", count), symbol: "pencil") {
                vm.promptForBatchRename(tasks: vm.selectedTasks)
            })
        }
        nodes.append(.divider)
        nodes += queueNodes
        nodes.append(.divider)
        nodes.append(.button(L10n.t("Remove %d from List", count), role: .destructive) {
            vm.removeSelected(deleteData: false)
        })
        nodes.append(.button(L10n.t("Remove %d and Move Files to Trash", count), symbol: "trash", role: .destructive) {
            vm.requestConfirm(
                title: L10n.t("Move the files of %d downloads to the Trash?", count),
                message: L10n.t("They are removed from the list. You can restore the files from the Trash."),
                confirmTitle: L10n.t("Move to Trash"),
                destructive: true
            ) { vm.removeSelected(deleteData: true) }
        })
        return nodes
    }

    func fullNodes() -> [DownloadMenuNode] {
        var nodes = primaryNodes()
        nodes.append(.divider)
        nodes += limitNodes()
        nodes.append(.divider)
        nodes += metadataNodes()
        nodes.append(.divider)
        nodes += queueNodes
        nodes.append(.divider)
        nodes += removalNodes()
        return nodes
    }

    private func primaryNodes() -> [DownloadMenuNode] {
        let task = self.task, vm = self.vm
        var nodes: [DownloadMenuNode] = []
        if task.status == .paused || task.status == .queued {
            nodes.append(.button(L10n.t("Resume"), symbol: "play") { vm.resume(task.id) })
        } else if task.status.isActive {
            nodes.append(.button(L10n.t("Pause"), symbol: "pause") { vm.pause(task.id) })
        }
        if task.status.isFailed {
            nodes.append(.button(L10n.t("Retry"), symbol: "arrow.clockwise") { vm.retry(task.id) })
        }
        nodes.append(.button(L10n.t("Open folder"), symbol: "folder") { vm.revealInFinder(task) })
        if task.status == .completed || playableWhileDownloading {
            nodes.append(.button(L10n.t("Open in Player"), symbol: "play.rectangle") { vm.openFile(task) })
        }
        if task.status == .completed {
            nodes.append(FileActionNodes.openWith(task, vm: vm))
            nodes.append(FileActionNodes.share(task, vm: vm))
        } else if !task.status.isFailed {
            nodes.append(FileActionNodes.whenDone(task, vm: vm))
        }
        if task.isMediaFile, task.status.hasData,
           InAppPlayback.canPlay(URL(fileURLWithPath: task.primaryFilePath)) {
            nodes.append(.button(L10n.t("Play in Goel°"), symbol: "play.circle") { vm.playInApp(task) })
        }
        if task.status.hasData {
            let quickLook = self.quickLook
            nodes.append(.button(L10n.t("Quick Look"), symbol: "eye") {
                quickLook(URL(fileURLWithPath: task.savePath))
            })
        }
        if task.status == .completed, task.isMediaFile {
            nodes.append(DownloadMenuNode(title: "", kind: .media(task, vm)))
        }
        nodes.append(.button(L10n.t("Copy source link"), symbol: "link") { vm.copyToPasteboard(task.sourceLocator) })
        if let prefix = context.streamLinkPrefix, RemoteStreamService.streamPlan(for: task) != nil {
            nodes.append(.button(L10n.t("Copy Stream Link"), symbol: "dot.radiowaves.left.and.right") {
                vm.copyToPasteboard("\(prefix)&id=\(task.id.uuidString)")
            })
        }
        return nodes
    }

    private func limitNodes() -> [DownloadMenuNode] {
        let task = self.task, vm = self.vm
        var nodes: [DownloadMenuNode] = [
            .submenu(L10n.t("Speed Limit"), symbol: "gauge.with.dots.needle.33percent",
                     limitChoices(current: task.speedLimitBytesPerSec) { vm.setTaskSpeedLimit($0, task: task.id) }),
        ]
        guard task.kind == .torrent else { return nodes }
        nodes.append(.toggle(L10n.t("Sequential Download"), isOn: task.sequentialDownload == true) {
            vm.setSequential($0, task: task.id)
        })
        nodes.append(.submenu(L10n.t("Upload Limit"), symbol: "arrow.up",
                              limitChoices(current: task.uploadLimitBytesPerSec) {
                                  vm.setTaskUploadLimit($0, task: task.id)
                              }))
        nodes.append(.submenu(L10n.t("Seed Until Ratio"), symbol: "leaf", seedRatioChoices()))
        if task.status.isActive || task.status == .seeding || task.status == .paused {
            nodes.append(.button(L10n.t("Force Recheck"), symbol: "checkmark.shield") { vm.forceRecheck(task.id) })
            nodes.append(.button(L10n.t("Re-announce to Trackers"), symbol: "antenna.radiowaves.left.and.right") {
                vm.forceReannounce(task.id)
            })
        }
        if case .magnet = task.source {
            nodes.append(.button(L10n.t("Copy Magnet Link"), symbol: "link") {
                vm.copyToPasteboard(task.sourceLocator)
            })
        }
        return nodes
    }

    private func metadataNodes() -> [DownloadMenuNode] {
        let task = self.task, vm = self.vm
        var nodes: [DownloadMenuNode] = []
        if task.kind != .torrent, !task.status.isActive {
            nodes.append(.button(L10n.t("Rename…"), symbol: "pencil") { vm.promptForRename(task: task) })
        }
        nodes.append(.button(task.allTags.isEmpty ? L10n.t("Add Tags…") : L10n.t("Edit Tags…"), symbol: "tag") {
            vm.promptForTags(task: task)
        })
        nodes.append(.button(task.note == nil ? L10n.t("Add Note…") : L10n.t("Edit Note…"), symbol: "note.text") {
            vm.promptForNote(task: task)
        })
        if task.kind == .http {
            nodes.append(.button(L10n.t("Request Options…"), symbol: "slider.horizontal.3") {
                vm.promptForRequestOptions(task: task)
            })
        }
        nodes.append(.button(task.label == nil ? L10n.t("Add Label…") : L10n.t("Edit Label…"), symbol: "bookmark") {
            vm.promptForLabel(task: task)
        })
        if task.status == .paused || task.status == .queued || task.status.isActive {
            var schedule: [DownloadMenuNode] = ScheduledStartOption.presets.map { preset in
                .button(preset.label) { vm.setScheduledStart(preset.date(), task: task.id) }
            }
            if task.scheduledAt != nil {
                schedule.append(.divider)
                schedule.append(.button(L10n.t("Cancel Scheduled Start")) { vm.setScheduledStart(nil, task: task.id) })
            }
            nodes.append(.submenu(L10n.t("Schedule Start"), symbol: "calendar", schedule))
        }
        return nodes
    }

    /// Acts on the selection when the item is part of one, else on this item.
    private var queueNodes: [DownloadMenuNode] {
        let id = task.id, vm = self.vm
        return [
            .button(L10n.t("Move to Top"), symbol: "arrow.up.to.line") {
                vm.moveInQueue(vm.queueTargets(for: id), to: .top)
            },
            .button(L10n.t("Move to Bottom"), symbol: "arrow.down.to.line") {
                vm.moveInQueue(vm.queueTargets(for: id), to: .bottom)
            },
        ]
    }

    private func removalNodes() -> [DownloadMenuNode] {
        let task = self.task, vm = self.vm
        return [
            .button(L10n.t("Remove from List"), role: .destructive) { vm.remove(task.id, deleteData: false) },
            .button(L10n.t("Remove and Move File to Trash"), symbol: "trash", role: .destructive) {
                vm.requestConfirm(
                    title: L10n.t("Move “%@” to the Trash?", task.compactDisplayName),
                    message: L10n.t("It is removed from the list. You can restore the file from the Trash."),
                    confirmTitle: L10n.t("Move to Trash"),
                    destructive: true
                ) { vm.remove(task.id, deleteData: true) }
            },
        ]
    }

    private var playableWhileDownloading: Bool {
        task.kind == .torrent
            && task.sequentialDownload == true
            && task.fileType == .video
            && task.fractionCompleted > 0.02
    }

    private static let limitSteps: [Int64] = [1, 2, 5, 10, 25].map { $0 * 1_000_000 }

    /// nil and 0 both mean "no per-task cap", so both tick Unlimited.
    private func limitChoices(current: Int64?, set: @escaping (Int64?) -> Void) -> [DownloadMenuNode] {
        let selected = current ?? 0
        return [.choice(L10n.t("Unlimited"), isOn: selected == 0) { set(nil) }]
            + Self.limitSteps.map { bytes in
                .choice(L10n.t("%d MB/s", Int(bytes / 1_000_000)), isOn: selected == bytes) { set(bytes) }
            }
    }

    /// nil means the profile's global limit applies; an explicit 0 seeds forever regardless of
    /// it. A custom ratio set elsewhere matches no preset, so nothing is ticked.
    private func seedRatioChoices() -> [DownloadMenuNode] {
        let task = self.task, vm = self.vm
        let presets: [Double?] = [nil, 0, 0.5, 1.0, 1.5, 2.0, 3.0]
        return presets.map { ratio in
            let isOn: Bool
            switch (ratio, task.seedRatioLimit) {
            case (nil, nil): isOn = true
            case (let r?, let current?): isOn = abs(r - current) < 0.001
            default: isOn = false
            }
            return .choice(seedRatioLabel(ratio), isOn: isOn) { vm.setSeedRatioLimit(ratio, task: task.id) }
        }
    }

    private func seedRatioLabel(_ ratio: Double?) -> String {
        switch ratio {
        case nil: return L10n.t("Profile default (%.1f×)", context.profileSeedRatio)
        case .some(let r) where r <= 0: return L10n.t("Seed indefinitely")
        case .some(let r): return String(format: "%.1f", r)
        }
    }
}
