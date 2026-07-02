import Foundation

/// One finished download, archived at the moment it first completed. History
/// outlives the queue: removing a task from the list (or the task list being
/// cleared) never touches its history row, so "what did I download in March"
/// keeps an answer. Entries are small on purpose — no resume blobs, no live
/// counters — just what re-downloading or finding the file again needs.
public struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    /// The task's id at completion time (also the archive row's identity).
    public let id: UUID
    public var name: String
    /// The re-addable source locator (URL / magnet link / torrent-file URL).
    public var locator: String
    public var kind: DownloadKind
    public var totalBytes: Int64?
    /// Where the payload landed. The file may have moved since — treat as a hint.
    public var savePath: String
    public var completedAt: Date

    public init(id: UUID, name: String, locator: String, kind: DownloadKind,
                totalBytes: Int64?, savePath: String, completedAt: Date) {
        self.id = id
        self.name = name
        self.locator = locator
        self.kind = kind
        self.totalBytes = totalBytes
        self.savePath = savePath
        self.completedAt = completedAt
    }

    /// Build the archive row for a task that just completed.
    public init(task: DownloadTask, completedAt: Date = Date()) {
        self.init(id: task.id, name: task.name, locator: task.source.locator,
                  kind: task.kind, totalBytes: task.totalBytes,
                  savePath: task.savePath,
                  completedAt: task.completedAt ?? completedAt)
    }
}
