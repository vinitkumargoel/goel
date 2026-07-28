import Foundation

struct AppExport: Codable, Sendable {
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
