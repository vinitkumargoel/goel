import Foundation

/// A failure (or outcome) the user must see that has no task row to carry it — a failed delete of a row
/// that is already gone, a skipped database row, a post-download step that went wrong.
public struct UserNotice: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let message: String
    public let taskID: UUID?
    public let isError: Bool

    public init(id: UUID = UUID(), message: String, taskID: UUID? = nil, isError: Bool = true) {
        self.id = id
        self.message = message
        self.taskID = taskID
        self.isError = isError
    }
}

extension DownloadManager {

    /// A headless daemon may never drain these, so the oldest go first rather than growing forever.
    static let maxPendingNotices = 50

    /// Returns and clears everything pending. Poll after each snapshot.
    public func takeNotices() -> [UserNotice] {
        let out = pendingNotices
        pendingNotices.removeAll()
        return out
    }

    public var hasPendingNotices: Bool { !pendingNotices.isEmpty }

    /// Publishes so an observer that polls on each snapshot sees the notice promptly.
    func postNotice(_ message: String, taskID: UUID? = nil, isError: Bool = true) {
        if isError {
            GoelLog.scheduler.error("User notice", .detail(message))
        } else {
            GoelLog.scheduler.notice("User notice", .detail(message))
        }
        pendingNotices.append(UserNotice(message: message, taskID: taskID, isError: isError))
        if pendingNotices.count > Self.maxPendingNotices {
            let dropped = pendingNotices.count - Self.maxPendingNotices
            pendingNotices.removeFirst(dropped)
            GoelLog.scheduler.error("Dropped undelivered user notices", .count(dropped, label: "dropped"))
        }
        publish()
    }
}
