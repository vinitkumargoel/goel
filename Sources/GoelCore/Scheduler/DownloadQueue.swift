import Foundation

public protocol DownloadQueue: AnyObject, Sendable {
    /// Call once after construction, before adding work.
    func restore() async

    func shutdown() async

    func taskSnapshot() async -> [DownloadTask]

    func pause(_ id: DownloadTask.ID) async
    func resume(_ id: DownloadTask.ID) async
    func retry(_ id: DownloadTask.ID) async
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async
    func pauseAll() async
    func resumeAll() async
}

extension DownloadManager: DownloadQueue {}
