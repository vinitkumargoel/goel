import Foundation

/// Full-fidelity export envelope — settings plus every task with complete state, so a queue survives a
/// machine move or reinstall. ``DownloadManager/exportEnvelope()`` writes it, `importEnvelope(_:)` reads it.
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
