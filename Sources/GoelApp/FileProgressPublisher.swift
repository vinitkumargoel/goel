import Foundation
import GoelCore

/// Finder's per-file progress. Runs on the snapshot pump (10 Hz), so both the `stat` and the
/// `Progress` writes are rationed: one unresponsive SMB share must not freeze the window.
@MainActor
final class FileProgressPublisher {

    /// Finder redraws its pie at about this rate anyway.
    static let updateInterval: TimeInterval = 1
    /// A file that appears (or vanishes) mid-download is noticed within this long.
    static let existenceRecheckInterval: TimeInterval = 5

    typealias PathProbe = (String) -> Bool

    private var published: [DownloadTask.ID: Progress] = [:]
    private var existence: [DownloadTask.ID: (path: String?, checkedAt: Date)] = [:]
    private var lastUpdate: Date = .distantPast
    private var lastLiveIDs: Set<DownloadTask.ID> = []
    private let now: () -> Date
    private let fileExists: PathProbe

    init(now: @escaping () -> Date = Date.init,
         fileExists: @escaping PathProbe = { FileManager.default.fileExists(atPath: $0) }) {
        self.now = now
        self.fileExists = fileExists
    }

    var publishedIDs: Set<DownloadTask.ID> { Set(published.keys) }

    func completedUnits(for id: DownloadTask.ID) -> Int64? { published[id]?.completedUnitCount }

    func update(with tasks: [DownloadTask],
                onCancel: @escaping @MainActor (DownloadTask.ID) -> Void) {
        let downloading = tasks.filter { $0.status == .downloading && ($0.totalBytes ?? 0) > 0 }
        let ids = Set(downloading.map(\.id))
        let clock = now()
        // A start or a finish is shown at once; only the byte counts wait for the next second.
        guard ids != lastLiveIDs || clock.timeIntervalSince(lastUpdate) >= Self.updateInterval else { return }
        lastUpdate = clock
        lastLiveIDs = ids
        existence = existence.filter { ids.contains($0.key) }

        var live = Set<DownloadTask.ID>()
        for task in downloading {
            guard let total = task.totalBytes, let path = onDiskPath(for: task, at: clock) else { continue }
            live.insert(task.id)
            let progress = published[task.id] ?? makeProgress(for: task, path: path, onCancel: onCancel)
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

    /// HTTP writes to `<name>.goelpart` until it finishes, so the final path doesn't exist yet.
    /// The answer is cached per task and re-probed at most every few seconds.
    private func onDiskPath(for task: DownloadTask, at clock: Date) -> String? {
        if let cached = existence[task.id],
           clock.timeIntervalSince(cached.checkedAt) < Self.existenceRecheckInterval {
            return cached.path
        }
        let candidates = [PartialFile.path(for: task.savePath), task.savePath]
        let found = candidates.first(where: fileExists)
        existence[task.id] = (found, clock)
        return found
    }

    private func makeProgress(for task: DownloadTask, path: String,
                              onCancel: @escaping @MainActor (DownloadTask.ID) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: task.totalBytes ?? 0)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.setUserInfoObject(URL(fileURLWithPath: path), forKey: .fileURLKey)
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
