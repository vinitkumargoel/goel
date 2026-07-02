import Foundation

/// The full-fidelity export envelope: settings plus every task with its
/// complete state. Written by ``DownloadManager/exportEnvelope()`` and read
/// back by ``DownloadManager/importEnvelope(_:)`` so a queue can move between
/// machines (or survive a reinstall) without losing progress or preferences.
public struct AppExport: Codable, Sendable {
    /// Format version for forward compatibility.
    public var version: Int

    public var exportedAt: Date
    public var settings: AppSettings
    public var tasks: [DownloadTask]

    public init(version: Int = 1, exportedAt: Date = Date(),
                settings: AppSettings, tasks: [DownloadTask]) {
        self.version = version
        self.exportedAt = exportedAt
        self.settings = settings
        self.tasks = tasks
    }
}
