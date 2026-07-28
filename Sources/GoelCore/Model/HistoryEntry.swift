import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var locator: String
    public var kind: DownloadKind
    public var totalBytes: Int64?
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

    public init(task: DownloadTask, completedAt: Date = Date()) {
        self.init(id: task.id, name: task.name, locator: task.source.locator,
                  kind: task.kind, totalBytes: task.totalBytes,
                  savePath: task.savePath,
                  completedAt: task.completedAt ?? completedAt)
    }
}
