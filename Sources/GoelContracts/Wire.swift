import Foundation

/// The remote-control / portal **wire contract**: the exact JSON-serializable
/// request and response shapes the app exchanges with a browser or a companion
/// client. Kept in the platform-free contract layer (rather than inside the
/// desktop-only `RemoteRouter`, which the mobile build drops) so this cross-language
/// contract survives on iOS/Android and can be pinned by golden-JSON tests.
///
/// These types are pure *shapes* — fields + `Codable` + a memberwise initializer.
/// The mapping from a domain object (`DownloadTask` → `Wire.TaskRow`, …) lives in
/// `GoelCore` (`Remote/RemoteWireMapping.swift`), because it needs engine-side
/// services (disk-I/O stream probing, the router's enum→token helpers) that do not
/// belong in the contract. Namespaced under `Wire` to avoid colliding with UI types
/// of the same name (e.g. the macOS app's own `TrackerRow` view).
public enum Wire {

    public struct AddPayload: Decodable {
        public var url: String
        public var folder: String?
        public var priority: String?
        public var paused: Bool?
    }

    public struct CountRow: Encodable {
        public var added: Int
        public init(added: Int) { self.added = added }
    }

    public struct ConfigRow: Encodable {
        public var username: String
        public var readOnly: Bool
        public var requireAuth: Bool
        public var theme: String
        public var appName: String
        public init(username: String, readOnly: Bool, requireAuth: Bool,
                    theme: String, appName: String = "Goel°") {
            self.username = username
            self.readOnly = readOnly
            self.requireAuth = requireAuth
            self.theme = theme
            self.appName = appName
        }
    }

    /// Compact per-task row for the live list.
    public struct TaskRow: Encodable {
        public var id: String
        public var name: String
        public var status: String        // display name ("Downloading")
        public var statusToken: String   // stable token ("downloading")
        public var kind: String          // "http" | "torrent" | "hls" | "ftp" | "sftp"
        public var progress: Double
        public var downSpeed: Double
        public var upSpeed: Double
        public var totalBytes: Int64?
        public var doneBytes: Int64
        public var upBytes: Int64
        public var ratio: Double
        public var seeds: Int?
        public var conns: Int
        public var addedAt: Double
        public var etaSeconds: Double?
        public var error: String?
        public var source: String
        public var multiFile: Bool
        public var fileCount: Int
        public var streamable: Bool

        public init(id: String, name: String, status: String, statusToken: String,
                    kind: String, progress: Double, downSpeed: Double, upSpeed: Double,
                    totalBytes: Int64?, doneBytes: Int64, upBytes: Int64, ratio: Double,
                    seeds: Int?, conns: Int, addedAt: Double, etaSeconds: Double?,
                    error: String?, source: String, multiFile: Bool, fileCount: Int,
                    streamable: Bool) {
            self.id = id
            self.name = name
            self.status = status
            self.statusToken = statusToken
            self.kind = kind
            self.progress = progress
            self.downSpeed = downSpeed
            self.upSpeed = upSpeed
            self.totalBytes = totalBytes
            self.doneBytes = doneBytes
            self.upBytes = upBytes
            self.ratio = ratio
            self.seeds = seeds
            self.conns = conns
            self.addedAt = addedAt
            self.etaSeconds = etaSeconds
            self.error = error
            self.source = source
            self.multiFile = multiFile
            self.fileCount = fileCount
            self.streamable = streamable
        }
    }

    /// The full detail for the selected task (files, trackers, peers, pieces).
    public struct TaskDetail: Encodable {
        public var row: TaskRow
        public var savePath: String
        public var sequential: Bool
        public var infoHash: String?
        public var files: [FileRow]
        public var trackers: [TrackerRow]
        public var connections: [ConnRow]
        public var pieces: [Double]
        public var server: String?
        public var mimeType: String?

        public init(row: TaskRow, savePath: String, sequential: Bool, infoHash: String?,
                    files: [FileRow], trackers: [TrackerRow], connections: [ConnRow],
                    pieces: [Double], server: String?, mimeType: String?) {
            self.row = row
            self.savePath = savePath
            self.sequential = sequential
            self.infoHash = infoHash
            self.files = files
            self.trackers = trackers
            self.connections = connections
            self.pieces = pieces
            self.server = server
            self.mimeType = mimeType
        }
    }

    public struct FileRow: Encodable {
        public var id: Int
        public var name: String
        public var size: Int64
        public var done: Int64
        public var progress: Double
        public var priority: String
        public init(id: Int, name: String, size: Int64, done: Int64,
                    progress: Double, priority: String) {
            self.id = id
            self.name = name
            self.size = size
            self.done = done
            self.progress = progress
            self.priority = priority
        }
    }

    public struct TrackerRow: Encodable {
        public var url: String
        public var host: String
        public var tier: Int
        public var status: String
        public var seeds: Int?
        public var leeches: Int?
        public var message: String
        public init(url: String, host: String, tier: Int, status: String,
                    seeds: Int?, leeches: Int?, message: String) {
            self.url = url
            self.host = host
            self.tier = tier
            self.status = status
            self.seeds = seeds
            self.leeches = leeches
            self.message = message
        }
    }

    public struct ConnRow: Encodable {
        public var id: String
        public var label: String
        public var detail: String
        public var down: Double
        public var up: Double
        public var progress: Double
        public var adapterId: String?
        public var adapterLabel: String?
        public init(id: String, label: String, detail: String, down: Double,
                    up: Double, progress: Double, adapterId: String?, adapterLabel: String?) {
            self.id = id
            self.label = label
            self.detail = detail
            self.down = down
            self.up = up
            self.progress = progress
            self.adapterId = adapterId
            self.adapterLabel = adapterLabel
        }
    }

    public struct HistoryRow: Encodable {
        public var id: String
        public var name: String
        public var kind: String
        public var totalBytes: Int64?
        public var savePath: String
        public var completedAt: Double
        public var source: String
        public init(id: String, name: String, kind: String, totalBytes: Int64?,
                    savePath: String, completedAt: Double, source: String) {
            self.id = id
            self.name = name
            self.kind = kind
            self.totalBytes = totalBytes
            self.savePath = savePath
            self.completedAt = completedAt
            self.source = source
        }
    }
}
