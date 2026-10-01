import AppKit
import Foundation
import GoelCore
import UniformTypeIdentifiers

/// What happens around a finished download: banners, the per-download "When done" choice,
/// Open With and the Dock menu.
extension AppViewModel {

    func postCompletionBanners(_ finished: [NotificationPlanning.Finished],
                               notifier: CompletionNotifying, sound: Bool) {
        completionBatcher.add(finished) { banner in
            switch banner {
            case .single(let one):
                notifier.postCompleted(taskID: one.taskID, name: one.name, sound: sound)
            case .summary(let count, let body):
                notifier.postCompletedSummary(count: count, body: body, sound: sound)
            }
        }
    }

    // MARK: - When done

    /// Open / Reveal / Open With need the window server, so the app runs them; Move to and Run
    /// script are the manager's. Only a transition seen live counts, never a restored row.
    func runWhenDoneActions(_ snapshot: [DownloadTask], previous: ReducerState) {
        guard previous.hasSeenFirstSnapshot else { return }
        let transitions = NotificationPlanning.transitions(snapshot, previous: previous.lastStatuses)
        pruneChainedAudio(snapshot, failed: transitions.failed)
        let done = transitions.completed
        for task in done {
            runChainedAudio(task)
            guard let whenDone = task.whenDone, whenDone.isActionable else { continue }
            switch whenDone.kind {
            case .open: openFile(task)
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.savePath)])
            case .openWith:
                if let app = whenDone.target { open(task, withApplicationAt: URL(fileURLWithPath: app)) }
            case .nothing, .moveTo, .runScript: break
            }
        }
    }

    /// A preset's pending extraction is dropped when its download fails or leaves the list,
    /// so a later retry or re-add never inherits it silently.
    private func pruneChainedAudio(_ snapshot: [DownloadTask], failed: [DownloadTask]) {
        guard !mediaJobs.chainedAudio.isEmpty else { return }
        mediaJobs.chainedAudio = MediaPreset.prunedChain(mediaJobs.chainedAudio,
                                                         listed: Set(snapshot.map(\.id)),
                                                         failed: Set(failed.map(\.id)))
    }

    /// An "Audio only" preset's second half: extract once the stream is on disk.
    private func runChainedAudio(_ task: DownloadTask) {
        guard let format = mediaJobs.chainedAudio.removeValue(forKey: task.id) else { return }
        let ext = (task.savePath as NSString).pathExtension
        guard MediaPreset.needsExtraction(format, downloadedExtension: ext) else { return }
        extractAudio(task: task, format: format)
    }

    func setWhenDone(_ whenDone: WhenDone?, task id: DownloadTask.ID) {
        Task { await manager.setWhenDone(whenDone, task: id) }
    }

    /// "Move to…" and "Open With…" need a place first; nil when the user cancels.
    static func chooseWhenDoneTarget(for kind: WhenDone.Kind) -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        switch kind {
        case .moveTo:
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = L10n.t("Choose")
        case .openWith:
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.prompt = L10n.t("Choose App")
        case .runScript:
            panel.canChooseDirectories = false
            panel.prompt = L10n.t("Choose Script")
        case .nothing, .open, .reveal:
            return nil
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: - Open With

    /// Apps that claim the finished file, the default one first.
    static func applications(forFile path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard let preferred = NSWorkspace.shared.urlForApplication(toOpen: url) else { return all }
        return [preferred] + all.filter { $0.standardizedFileURL != preferred.standardizedFileURL }
    }

    func open(_ task: DownloadTask, withApplicationAt app: URL) {
        let file = URL(fileURLWithPath: task.primaryFilePath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            toastNow(L10n.t("“%@” was moved or deleted", task.name), isError: true)
            return
        }
        let name = task.name
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: .init()) { _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                self?.toastNow(L10n.t("Couldn’t open “%@” with that app", name), isError: true)
            }
        }
    }

    func openWithOtherApp(_ task: DownloadTask) {
        guard let app = Self.chooseWhenDoneTarget(for: .openWith) else { return }
        open(task, withApplicationAt: URL(fileURLWithPath: app))
    }

    /// The share sheet anchored to whatever view asked; the file must still be there.
    func share(_ task: DownloadTask, from view: NSView?) {
        let file = URL(fileURLWithPath: task.primaryFilePath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            toastNow(L10n.t("“%@” was moved or deleted", task.name), isError: true)
            return
        }
        let picker = NSSharingServicePicker(items: [file])
        guard let anchor = view ?? NSApp.keyWindow?.contentView else { return }
        let point = anchor.window?.mouseLocationOutsideOfEventStream ?? .zero
        let local = anchor.convert(point, from: nil)
        picker.show(relativeTo: NSRect(origin: local, size: .init(width: 1, height: 1)), of: anchor, preferredEdge: .minY)
    }
}
