import Foundation

/// One file inside a transfer. A plain HTTP download is the one-file case;
/// a torrent is often many files with per-file selection and priority.
public struct TransferFile: Identifiable, Codable, Sendable, Hashable {
    public var id: Int               // stable index within the task
    public var path: String          // relative path within the save folder
    public var length: Int64
    public var bytesCompleted: Int64
    public var priority: FilePriority

    public init(
        id: Int,
        path: String,
        length: Int64,
        bytesCompleted: Int64 = 0,
        priority: FilePriority = .normal
    ) {
        self.id = id
        self.path = path
        self.length = length
        self.bytesCompleted = bytesCompleted
        self.priority = priority
    }

    /// Whether the user wants this file (skip = deselected).
    public var isWanted: Bool { priority != .skip }

    public var fractionCompleted: Double {
        guard length > 0 else { return bytesCompleted > 0 ? 1 : 0 }
        return min(1, Double(bytesCompleted) / Double(length))
    }

    /// The file's display name (last path component).
    public var name: String {
        (path as NSString).lastPathComponent
    }
}
