import Foundation

public struct TransferFile: Identifiable, Codable, Sendable, Hashable {
    public var id: Int
    public var path: String
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

    public var isWanted: Bool { priority != .skip }

    public var fractionCompleted: Double {
        guard length > 0 else { return bytesCompleted > 0 ? 1 : 0 }
        return min(1, Double(bytesCompleted) / Double(length))
    }

    public var name: String {
        (path as NSString).lastPathComponent
    }
}
