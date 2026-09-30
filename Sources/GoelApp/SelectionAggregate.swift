import Foundation
import GoelCore

/// What the detail panel says about a multi-row selection: how many, how big, how far along,
/// how fast, and which bulk commands would do anything. Pure, so the panel only draws it.
struct SelectionAggregate {
    let count: Int
    /// Declared sizes, or bytes so far where a size was never declared.
    let totalBytes: Int64
    let activeCount: Int
    let failedCount: Int
    let completedCount: Int
    /// Bytes done over bytes known, so a 4 GB download at 50% outweighs a 10 MB one at 100%.
    /// Rows without a known size fall back to a plain mean when no row has one.
    let fraction: Double
    let speed: SpeedSample
    /// The first few rows, for the stacked tiles.
    let preview: [DownloadTask]

    let canResume: Bool
    let canPause: Bool
    let canRetry: Bool
    /// Some row is stopped and unfinished, so "Move to…" has something to move.
    let canMove: Bool

    static let previewLimit = 3

    /// "3 selected · 4.7 GB": the status bar's echo of the selection, so it reads without the panel.
    static func statusLine(count: Int, totalBytes: Int64) -> String {
        totalBytes > 0 ? L10n.t("%1$d selected · %2$@", count, totalBytes.byteString)
                       : L10n.t("%d selected", count)
    }

    init(tasks: [DownloadTask], speed: (DownloadTask) -> SpeedSample) {
        count = tasks.count
        var bytes: Int64 = 0
        var knownTotal: Int64 = 0
        var knownDone: Int64 = 0
        var active = 0, failed = 0, completed = 0
        var down = 0.0, up = 0.0
        for task in tasks {
            bytes += task.totalBytes ?? task.bytesDownloaded
            if let total = task.totalBytes, total > 0 {
                knownTotal += total
                knownDone += min(task.bytesDownloaded, total)
            }
            if task.status.isActive { active += 1 }
            if task.status.isFailed { failed += 1 }
            if task.status == .completed { completed += 1 }
            let sample = speed(task)
            down += sample.down
            up += sample.up
        }
        totalBytes = bytes
        activeCount = active
        failedCount = failed
        completedCount = completed
        if knownTotal > 0 {
            fraction = min(1, Double(knownDone) / Double(knownTotal))
        } else if !tasks.isEmpty {
            fraction = tasks.reduce(0) { $0 + $1.fractionCompleted } / Double(tasks.count)
        } else {
            fraction = 0
        }
        self.speed = SpeedSample(down: down, up: up)
        preview = Array(tasks.prefix(Self.previewLimit))
        // The same rules as the list's bulk context menu, so the two never disagree.
        canResume = tasks.contains { $0.status == .paused || $0.status == .queued }
        canPause = tasks.contains { $0.status.isActive }
        canRetry = tasks.contains { $0.status.isFailed }
        canMove = tasks.contains { !$0.status.isActive && $0.status != .completed }
    }

    /// "5 downloads selected"
    var title: String { L10n.t("%d downloads selected", count) }

    /// "11.2 GB · 3 active · 1 failed" — zero counts are left out.
    var subtitle: String {
        var parts: [String] = []
        if totalBytes > 0 { parts.append(totalBytes.byteString) }
        if activeCount > 0 { parts.append(L10n.t("%d active", activeCount)) }
        if failedCount > 0 { parts.append(L10n.t("%d failed", failedCount)) }
        if completedCount > 0 { parts.append(L10n.t("%d done", completedCount)) }
        return parts.joined(separator: " · ")
    }
}
