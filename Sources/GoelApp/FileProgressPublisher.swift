import Foundation
import GoelCore

@MainActor
final class FileProgressPublisher {

    private var published: [DownloadTask.ID: Progress] = [:]

    func update(with tasks: [DownloadTask],
                onCancel: @escaping @MainActor (DownloadTask.ID) -> Void) {
        var live = Set<DownloadTask.ID>()
        for task in tasks where task.status == .downloading {
            guard let total = task.totalBytes, total > 0,
                  FileManager.default.fileExists(atPath: task.savePath) else { continue }
            live.insert(task.id)
            let progress = published[task.id] ?? makeProgress(for: task, onCancel: onCancel)
            progress.totalUnitCount = total
            // `bytesDownloaded` can exceed `total` (revised Content-Length, segmented overshoot).
            let delivered = min(task.bytesDownloaded, total)
            progress.completedUnitCount = delivered
            progress.setUserInfoObject(NSNumber(value: task.downloadSpeed), forKey: .throughputKey)
            if task.downloadSpeed > 0 {
                let remaining = Double(total - delivered) / task.downloadSpeed
                progress.setUserInfoObject(NSNumber(value: remaining),
                                           forKey: .estimatedTimeRemainingKey)
            } else {
                // At 0 B/s the previous estimate is stale; without clearing, Finder freezes it.
                progress.setUserInfoObject(nil, forKey: .estimatedTimeRemainingKey)
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
