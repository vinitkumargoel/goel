import Foundation

/// The full-fidelity export envelope: settings plus every task with its
/// complete state. Written by ``DownloadManager/exportEnvelope()`` and read
/// back by ``DownloadManager/importEnvelope(_:)`` so a queue can move between
/// machines (or survive a reinstall) without losing progress or preferences.
struct AppExport: Codable, Sendable {
    /// Format version for forward compatibility.
    var version: Int

    var exportedAt: Date
    var settings: AppSettings
    var tasks: [DownloadTask]

    init(version: Int = 1, exportedAt: Date = Date(),
                settings: AppSettings, tasks: [DownloadTask]) {
        self.version = version
        self.exportedAt = exportedAt
        self.settings = settings
        self.tasks = tasks
    }
}
