#if DEBUG
import SwiftUI
import GoelCore

/// Realistic downloads for snapshots and previews, without a running engine.
///
/// - `StudioSampleData.tasks` — the eleven sample downloads as plain `DownloadTask` values.
/// - `StudioSampleData.task(.ubuntu)` — one of them by name.
/// - `StudioSampleData.makeViewModel()` — an `AppViewModel` showing them. It is built through
///   `AppViewModel.init(system:opened:manager:settings:)` with an in-memory `PersistenceStore`,
///   inert engines and no-op platform ports, and `start()` is never called: no database file,
///   no engine, no Keychain, no network, no settings written.
@MainActor
enum StudioSampleData {

    enum ID: String, CaseIterable {
        case ubuntu, debian, cosmos, backup, magnet, imagenet, bunny, fedora, fieldRecordings, figma, boardPack

        /// Stable, so a snapshot can select a task by name across runs.
        var uuid: UUID {
            let index = ID.allCases.firstIndex(of: self) ?? 0
            return UUID(uuidString: String(format: "5D1A0000-0000-4000-8000-%012d", index + 1)) ?? UUID()
        }
    }

    static func task(_ id: ID) -> DownloadTask {
        tasks.first { $0.id == id.uuid } ?? tasks[0]
    }

    /// Decimal units and the Downloads folder, shared by every area's sample data.
    static let gb: Int64 = 1_000_000_000
    static let mb: Int64 = 1_000_000
    static let downloads = "\(NSHomeDirectory())/Downloads"

    /// In the order the board shows them: active, up next, needs you, done.
    static var tasks: [DownloadTask] {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let ubuntu = DownloadTask(
            id: ID.ubuntu.uuid,
            source: .url(URL(string: "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso")!),
            name: "ubuntu-24.04.1-desktop-amd64.iso",
            saveDirectory: "\(downloads)/Disc images",
            totalBytes: 4_700 * mb, bytesDownloaded: 2_914 * mb,
            downloadSpeed: 12 * Double(mb),
            status: .downloading, connectionCount: 8, addedAt: ago(14),
            connections: (1...8).map { index in
                TaskConnection(id: "c\(index)", label: "#\(index)", detail: "releases.ubuntu.com",
                               downloadSpeed: 1.5 * Double(mb), progress: 0.55 + Double(index) * 0.02)
            },
            remoteInfo: nil,
            tags: ["linux"])

        let debian = DownloadTask(
            id: ID.debian.uuid,
            source: .magnet("magnet:?xt=urn:btih:9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b&dn=debian-12.6.0-amd64-DVD-1.iso"),
            name: "debian-12.6.0-amd64-DVD-1.iso",
            saveDirectory: "\(downloads)/Disc images",
            totalBytes: 3_900 * mb, bytesDownloaded: 3_900 * mb, bytesUploaded: 4_680 * mb,
            uploadSpeed: 1.8 * Double(mb),
            status: .seeding,
            files: [TransferFile(id: 0, path: "debian-12.6.0-amd64-DVD-1.iso", length: 3_900 * mb, bytesCompleted: 3_900 * mb)],
            connectionCount: 12, addedAt: ago(300), completedAt: ago(120),
            seedCount: 44, infoHash: "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b",
            trackers: [TorrentTracker(url: "udp://tracker.debian.org:6969/announce", seeds: 412, leeches: 18, status: .working, verified: true)],
            seedRatioLimit: 2.0)

        let cosmosFiles = [
            TransferFile(id: 0, path: "Cosmos.S01E04/Cosmos.S01E04.2160p.HDR.mkv", length: 16_800 * mb, bytesCompleted: 6_890 * mb, priority: .high),
            TransferFile(id: 1, path: "Cosmos.S01E04/Subs/English.srt", length: 120_000, bytesCompleted: 120_000),
            TransferFile(id: 2, path: "Cosmos.S01E04/Sample/sample.mkv", length: 200 * mb, bytesCompleted: 0, priority: .skip),
        ]
        let cosmos = DownloadTask(
            id: ID.cosmos.uuid,
            source: .magnet("magnet:?xt=urn:btih:3c1f2e9d8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d&dn=Cosmos.S01E04.2160p.HDR.mkv"),
            name: "Cosmos.S01E04.2160p.HDR.mkv",
            saveDirectory: "\(downloads)/Video",
            totalBytes: 17_000 * mb, bytesDownloaded: 6_970 * mb, bytesUploaded: 410 * mb,
            downloadSpeed: 24 * Double(mb), uploadSpeed: 640_000,
            status: .downloading, files: cosmosFiles, connectionCount: 38, addedAt: ago(9),
            seedCount: 31, infoHash: "3c1f2e9d8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d",
            trackers: [
                TorrentTracker(url: "udp://tracker.opentrackr.org:1337/announce", seeds: 120, leeches: 40, status: .working, verified: true),
                TorrentTracker(url: "udp://open.stealth.si:80/announce", tier: 1, message: "Connection timed out", status: .error),
            ],
            pieceAvailability: (0..<160).map { index in index % 7 == 0 ? 0.4 : (index < 66 ? 1 : 0) })

        let backup = DownloadTask(
            id: ID.backup.uuid,
            source: .url(URL(string: "sftp://nas.home/volume1/backups/project-backup-2026-07.tar.zst")!),
            name: "project-backup-2026-07.tar.zst",
            saveDirectory: "\(downloads)/Archives",
            totalBytes: 2_200 * mb, bytesDownloaded: 1_716 * mb,
            downloadSpeed: 7.7 * Double(mb),
            status: .downloading, connectionCount: 1, addedAt: ago(6))

        let magnet = DownloadTask(
            id: ID.magnet.uuid,
            source: .magnet("magnet:?xt=urn:btih:5c1a9d3e7b2f4a6c8d0e1f3a5b7c9d1e3f5a7b9c"),
            name: "Magnet download",
            saveDirectory: downloads,
            status: .requestingMetadata, addedAt: ago(1),
            infoHash: "5c1a9d3e7b2f4a6c8d0e1f3a5b7c9d1e3f5a7b9c")

        let imagenet = DownloadTask(
            id: ID.imagenet.uuid,
            source: .url(URL(string: "https://datasets.example.org/imagenet-mini-dataset.zip")!),
            name: "imagenet-mini-dataset.zip",
            saveDirectory: "\(downloads)/Archives",
            totalBytes: 3_300 * mb, bytesDownloaded: 1_122 * mb,
            status: .paused, connectionCount: 0, addedAt: ago(95))

        let bunny = DownloadTask(
            id: ID.bunny.uuid,
            source: .hlsStream(URL(string: "https://media.example.org/bbb/master.m3u8")!),
            name: "BigBuckBunny-1080p.mp4",
            saveDirectory: "\(downloads)/Video",
            totalBytes: 340 * mb, bytesDownloaded: 340 * mb,
            status: .completed, addedAt: ago(70), completedAt: ago(52))

        let fedora = DownloadTask(
            id: ID.fedora.uuid,
            source: .url(URL(string: "ftp://ftp.example.org/fedora/Fedora-Workstation-40.iso")!),
            name: "Fedora-Workstation-40.iso",
            saveDirectory: "\(downloads)/Disc images",
            totalBytes: 2_300 * mb, bytesDownloaded: 690 * mb,
            status: .failed(.network("FTP server closed the connection")), addedAt: ago(40),
            retryAttempt: 2)

        let field = DownloadTask(
            id: ID.fieldRecordings.uuid,
            source: .url(URL(string: "https://audio.example.org/field-recordings/Field%20Recordings%20Vol.%203.flac")!),
            name: "Field Recordings Vol. 3.flac",
            saveDirectory: "\(downloads)/Audio",
            totalBytes: 1_300 * mb,
            status: .queued, addedAt: ago(3), queuePosition: 2)

        let figma = DownloadTask(
            id: ID.figma.uuid,
            source: .url(URL(string: "https://desktop.figma.com/mac-arm/Figma-126.4.dmg")!),
            name: "Figma-126.4.dmg",
            saveDirectory: "\(downloads)/Apps",
            totalBytes: 412 * mb,
            status: .queued, addedAt: ago(2), queuePosition: 3)

        let board = DownloadTask(
            id: ID.boardPack.uuid,
            source: .url(URL(string: "https://files.example.com/q3/Q3-board-pack.pdf")!),
            name: "Q3-board-pack.pdf",
            saveDirectory: "\(downloads)/Documents",
            totalBytes: 8_400_000, bytesDownloaded: 8_400_000,
            status: .completed, addedAt: ago(100), completedAt: ago(85))

        return [ubuntu, cosmos, backup, magnet, field, figma, fedora, imagenet, bunny, board, debian]
    }

    /// One model per process: building it is cheap but views compare identity across passes.
    private static var cachedModel: AppViewModel?

    static func makeViewModel(selecting selected: ID? = .ubuntu) -> AppViewModel {
        if let cachedModel {
            cachedModel.installSampleSnapshot(tasks, selecting: selected?.uuid)
            return cachedModel
        }
        var settings = AppSettings()
        settings.theme = StudioAppearanceMode.system.storedValue
        settings.clipboardMonitorEnabled = false
        let store = try? PersistenceStore()
        let opened = AppViewModel.OpenedStore(store: store)
        let manager = DownloadManager(
            httpEngine: InertEngine(kind: .http),
            torrentEngine: InertEngine(kind: .torrent),
            hlsEngine: InertEngine(kind: .hls),
            ftpEngine: InertEngine(kind: .ftp),
            sftpEngine: InertEngine(kind: .sftp),
            settings: settings,
            store: store,
            power: InertPlatform(),
            folderWatch: InertPlatform(),
            scanner: InertPlatform(),
            credentials: InertPlatform())
        let model = AppViewModel(system: InertPlatform(), opened: opened, manager: manager, settings: settings)
        model.installSampleSnapshot(tasks, selecting: selected?.uuid)
        seedTelemetry(model)
        cachedModel = model
        return model
    }

    /// A minute of speed history for every active task and the status bar, shaped like the
    /// mockup's rising sparkline.
    private static func seedTelemetry(_ model: AppViewModel) {
        let base = tasks
        let start = Date().addingTimeInterval(-60)
        for tick in 0..<60 {
            let wobble = sin(Double(tick) / 4) * 0.18 + Double(tick) / 120
            let sampled = base.map { task -> DownloadTask in
                var copy = task
                copy.downloadSpeed = task.downloadSpeed * (0.62 + wobble)
                copy.uploadSpeed = task.uploadSpeed * (0.8 + wobble / 2)
                return copy
            }
            let down = sampled.reduce(0) { $0 + $1.downloadSpeed }
            let up = sampled.reduce(0) { $0 + $1.uploadSpeed }
            model.telemetry.sample(tasks: sampled, combined: SpeedSample(down: down, up: up),
                                   recordHistory: true, now: start.addingTimeInterval(Double(tick)))
        }
        let down = base.reduce(0) { $0 + $1.downloadSpeed }
        let up = base.reduce(0) { $0 + $1.uploadSpeed }
        model.telemetry.sample(tasks: base, combined: SpeedSample(down: down, up: up), recordHistory: true)
    }
}

extension View {
    /// Injects the sample model and its stores, the way the app's scenes inject the live ones.
    @MainActor
    func studioSampleEnvironment() -> some View {
        studioSampleEnvironment(StudioSampleData.makeViewModel())
    }

    @MainActor
    func studioSampleEnvironment(_ model: AppViewModel) -> some View {
        environmentObject(model)
            .environmentObject(model.telemetry)
            .environmentObject(model.sftpStore)
    }
}

/// An engine that accepts every call and does nothing, so a sample `DownloadManager` never
/// touches the network or disk.
private final class InertEngine: DownloadEngine {
    let kind: DownloadKind

    init(kind: DownloadKind) {
        self.kind = kind
    }

    func add(_ task: DownloadTask) async {}
    func pause(_ id: DownloadTask.ID) async {}
    func resume(_ id: DownloadTask.ID) async {}
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async {}
    func applyLimits(_ profile: TrafficProfile) async {}

    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        AsyncStream { $0.finish() }
    }
}

/// No-op platform ports: no power assertions, no folder watching, no antivirus, no Keychain,
/// no notifications, no shutdown.
private struct InertPlatform: PowerControlling, FolderWatching, FileScanning, CredentialManaging, SystemActions {
    func setPreventSleep(_ on: Bool) {}
    var isOnBattery: Bool { false }

    func start(path: String, onNewTorrent: @escaping @Sendable (URL) -> Void) async {}
    func stop() async {}

    func scan(path: String, executablePath: String, argumentTemplate: String) async -> ScanResult { .clean }

    func credential(forHost host: String) -> (username: String, password: String)? { nil }
    func setCredential(username: String, password: String, host: String) -> Bool { false }
    func removeCredential(host: String) -> Bool { false }
    func allCredentials() -> [HostCredential] { [] }
    func lookupCredential(forHost host: String) -> CredentialLookup { .notFound }
    func storeCredential(username: String, password: String, host: String) -> CredentialWrite { .failed(status: 0) }

    func post(_ notifications: [AppNotification], sound: Bool) {}
    func perform(_ intent: DrainIntent) {}
}
#endif
