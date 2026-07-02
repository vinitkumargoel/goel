import Foundation
import AppKit
import GoelCore

/// Publishes an `NSProgress` per actively-downloading task, keyed to its
/// destination file, so Finder overlays the same progress pie Safari's
/// downloads get — and the user can cancel from Finder (which pauses here).
///
/// Publication follows the task's live status exactly: a task entering
/// `.downloading` publishes, anything else (pause, completion, failure,
/// removal) unpublishes. Files must exist on disk before Finder will overlay
/// them; the engines preallocate on start, so that's true from the first tick.
@MainActor
final class FileProgressPublisher {

    private var published: [DownloadTask.ID: Progress] = [:]

    /// Reconcile the published set against a task snapshot. `onCancel` runs on
    /// the main actor when the user cancels a download from Finder.
    func update(with tasks: [DownloadTask],
                onCancel: @escaping @MainActor (DownloadTask.ID) -> Void) {
        var live = Set<DownloadTask.ID>()
        for task in tasks where task.status == .downloading {
            guard let total = task.totalBytes, total > 0,
                  FileManager.default.fileExists(atPath: task.savePath) else { continue }
            live.insert(task.id)
            let progress = published[task.id] ?? makeProgress(for: task, onCancel: onCancel)
            progress.totalUnitCount = total
            progress.completedUnitCount = min(task.bytesDownloaded, total)
            progress.setUserInfoObject(NSNumber(value: task.downloadSpeed), forKey: .throughputKey)
            if task.downloadSpeed > 0 {
                let remaining = Double(total - task.bytesDownloaded) / task.downloadSpeed
                progress.setUserInfoObject(NSNumber(value: remaining),
                                           forKey: .estimatedTimeRemainingKey)
            }
        }
        for (id, progress) in published where !live.contains(id) {
            progress.unpublish()
            published.removeValue(forKey: id)
        }
    }

    private func makeProgress(for task: DownloadTask,
                              onCancel: @escaping @MainActor (DownloadTask.ID) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: task.totalBytes ?? 0)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.setUserInfoObject(URL(fileURLWithPath: task.savePath), forKey: .fileURLKey)
        progress.isCancellable = true
        let id = task.id
        // Finder invokes this on an arbitrary queue; hop back to the UI actor.
        progress.cancellationHandler = {
            Task { @MainActor in onCancel(id) }
        }
        progress.publish()
        published[task.id] = progress
        return progress
    }
}
