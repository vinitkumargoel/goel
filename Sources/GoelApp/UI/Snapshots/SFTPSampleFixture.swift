#if DEBUG
import Foundation
import GoelCore

/// Sample servers, a remote folder and transfers for the SFTP snapshots (`--studio-snapshots`),
/// and the one set of servers and transfers every other area's snapshots draw from too.
/// Fixed ids and dates, so renders are stable. Nothing here reaches a server or the Keychain.
@MainActor
enum SFTPSampleFixture {

    static let nas = SFTPConnection(
        id: UUID(uuidString: "5F7A0000-0000-4000-8000-000000000001")!,
        name: "nas.home", host: "nas.home", port: 22, username: "vinit",
        initialPath: "/home/vinit/backups", useAgent: false, privateKeyPath: "~/.ssh/id_ed25519")

    static let seedbox = SFTPConnection(
        id: UUID(uuidString: "5F7A0000-0000-4000-8000-000000000002")!,
        name: "seedbox-ams", host: "ams3.seedbox.example.net", port: 22, username: "vinit",
        initialPath: "/home/vinit/done")

    static let path = "/home/vinit/backups"

    static let volume = SFTPVolumeSpace(totalBytes: 4_000_000_000_000, freeBytes: 1_200_000_000_000)

    private static let mb = StudioSampleData.mb

    /// 2026-10-01 18:00 UTC, and days before it.
    private static func day(_ daysAgo: Double, hour: Double = 0) -> Date {
        Date(timeIntervalSince1970: 1_790_877_600 - daysAgo * 86_400 + hour * 3_600)
    }

    static let entries: [SFTPEntry] = [
        SFTPEntry(name: "2024", isDirectory: true, size: 4096, modified: day(270), permissions: 0o755,
                  ownerID: 1000, groupID: 100),
        SFTPEntry(name: "2025", isDirectory: true, size: 4096, modified: day(40), permissions: 0o755,
                  ownerID: 1000, groupID: 100),
        SFTPEntry(name: "photos-raw", isDirectory: true, size: 4096, modified: day(3), permissions: 0o750,
                  ownerID: 1000, groupID: 100),
        SFTPEntry(name: "scripts", isDirectory: true, size: 4096, modified: day(50), permissions: 0o755,
                  ownerID: 1000, groupID: 100),
        SFTPEntry(name: "vm-images", isDirectory: true, size: 4096, modified: day(12), permissions: 0o700,
                  ownerID: 1000, groupID: 100),
        SFTPEntry(name: "project-backup-2026-07.tar.zst", isDirectory: false, size: 2_300 * mb,
                  modified: day(1, hour: -3), permissions: 0o640, ownerID: 1000, groupID: 100),
        SFTPEntry(name: "project-backup-2026-06.tar.zst", isDirectory: false, size: 2_100 * mb,
                  modified: day(1, hour: 4), permissions: 0o640, ownerID: 1000, groupID: 100),
        SFTPEntry(name: "db-dump-2026-10-01.sql.gz", isDirectory: false, size: 840 * mb,
                  modified: day(0, hour: 2), permissions: 0o600, ownerID: 1000, groupID: 100),
        SFTPEntry(name: "latest.tar.zst", isDirectory: false, size: 43, modified: day(0, hour: 3),
                  permissions: 0o777, isSymlink: true, linkTarget: "project-backup-2026-07.tar.zst",
                  ownerID: 1000, groupID: 100),
        SFTPEntry(name: "notes.md", isDirectory: false, size: 4_200, modified: day(3, hour: 9),
                  permissions: 0o644, ownerID: 1000, groupID: 100),
        SFTPEntry(name: "restore.sh", isDirectory: false, size: 2_048, modified: day(50, hour: 2),
                  permissions: 0o755, ownerID: 1000, groupID: 100),
        SFTPEntry(name: ".env", isDirectory: false, size: 310, modified: day(80), permissions: 0o600,
                  ownerID: 1000, groupID: 100),
    ]

    static func entry(_ name: String) -> SFTPEntry {
        entries.first { $0.name == name } ?? entries[0]
    }

    static func info(for entry: SFTPEntry) -> SFTPEntryInfo {
        SFTPEntryInfo(name: entry.name, path: SFTPBrowserPaths.join(path, entry.name),
                      attributes: SFTPAttributes(exists: true, isDirectory: entry.isDirectory,
                                                 isSymlink: entry.isSymlink, size: entry.size,
                                                 modified: entry.modified, permissions: entry.permissions,
                                                 ownerID: entry.ownerID, groupID: entry.groupID),
                      linkTarget: entry.isSymlink ? entry.linkTarget : nil)
    }

    // MARK: - Transfers

    private static let downloads = StudioSampleData.downloads

    static func transfers() -> [SFTPTransfer] {
        let now = Date()
        var backup = SFTPTransfer(connectionID: nas.id, name: "project-backup-2026-07.tar.zst",
                                  direction: .download, isDirectory: false,
                                  localURL: URL(fileURLWithPath: "\(downloads)/Archives/project-backup-2026-07.tar.zst"),
                                  remotePath: "\(path)/project-backup-2026-07.tar.zst", total: 2_300 * mb)
        backup.record(bytes: 1, now: now.addingTimeInterval(-240))
        backup.record(bytes: 1_794 * mb, now: now)
        backup.sampledSpeed = 7.7 * Double(mb)
        backup.peakSpeed = 9.4 * Double(mb)

        var deck = SFTPTransfer(connectionID: nas.id, name: "Q3-board-pack.pdf", direction: .upload,
                                isDirectory: false,
                                localURL: URL(fileURLWithPath: "\(downloads)/Q3-board-pack.pdf"),
                                remotePath: "\(path)/Q3-board-pack.pdf", total: 8_400_000)

        var bunny = SFTPTransfer(connectionID: nas.id, name: "BigBuckBunny-1080p.mp4", direction: .upload,
                                 isDirectory: false,
                                 localURL: URL(fileURLWithPath: "\(downloads)/BigBuckBunny-1080p.mp4"),
                                 remotePath: "\(path)/BigBuckBunny-1080p.mp4", total: 340 * mb)
        bunny.record(bytes: 1, now: now.addingTimeInterval(-60))
        bunny.record(bytes: 120 * mb, now: now.addingTimeInterval(-20))
        bunny.state = .paused

        var logs = SFTPTransfer(connectionID: nas.id, name: "old-logs.tar", direction: .download,
                                isDirectory: false,
                                localURL: URL(fileURLWithPath: "\(downloads)/old-logs.tar"),
                                remotePath: "/var/log/old-logs.tar", total: 0)
        logs.state = .failed("Permission denied (the server refused to open /var/log/old-logs.tar)")

        var dump = SFTPTransfer(connectionID: seedbox.id, name: "Sprite.Fright.2021.mkv", direction: .download,
                                isDirectory: false,
                                localURL: URL(fileURLWithPath: "\(downloads)/Sprite.Fright.2021.mkv"),
                                remotePath: "/home/vinit/done/Sprite.Fright.2021.mkv", total: 1_400 * mb)
        dump.record(bytes: 1, now: now.addingTimeInterval(-300))
        dump.record(bytes: 1_400 * mb, now: now.addingTimeInterval(-120))
        dump.state = .finished
        dump.endedAt = now.addingTimeInterval(-120)
        dump.peakSpeed = 11.2 * Double(mb)

        deck.state = .waiting
        return [backup, deck, bunny, logs, dump]
    }

    /// The running download and the paused upload: one of each direction and state, for the
    /// menu bar's and status bar's transfer rows.
    static func activeTransfers() -> [SFTPTransfer] {
        transfers().filter { $0.state == .running || $0.state == .paused }
    }

    /// A minute of throughput for the running download, for the panel's graph.
    static func history(for transfers: [SFTPTransfer]) -> [UUID: [Double]] {
        var map: [UUID: [Double]] = [:]
        for transfer in transfers where transfer.state == .running {
            map[transfer.id] = (0..<60).map { i in
                let x = Double(i)
                return (6.2 + 1.4 * sin(x / 5) + 0.8 * sin(x / 1.7) + x / 40) * Double(mb)
            }
        }
        return map
    }

    static func meta() -> [SFTPConnection.ID: ServerMeta] {
        [
            nas.id: ServerMeta(reachability: .online, ip: "192.168.0.20", latencyMS: 12,
                               os: ServerOS(id: "debian", pretty: "Debian GNU/Linux 12 (bookworm)")),
            seedbox.id: ServerMeta(reachability: .online, ip: "185.12.4.9", latencyMS: 38),
        ]
    }

    /// Puts the sample servers and transfers into the shared sample view model.
    static func install(into vm: AppViewModel, transfers: [SFTPTransfer]? = nil) {
        vm.servers = [nas, seedbox]
        vm.serverMeta = meta()
        vm.sftpTransfers = transfers ?? Self.transfers()
        vm.sftpClipboard = nil
    }

    static func conflictRequest() -> SFTPUploadConflictRequest {
        let items = [
            SFTPUploadConflictRequest.Item(url: URL(fileURLWithPath: "\(downloads)/Q3-board-pack.pdf"), isDirectory: false),
            SFTPUploadConflictRequest.Item(url: URL(fileURLWithPath: "\(downloads)/BigBuckBunny-1080p.mp4"), isDirectory: false),
            SFTPUploadConflictRequest.Item(url: URL(fileURLWithPath: "\(downloads)/scripts"), isDirectory: true),
        ]
        return SFTPUploadConflictRequest(connection: seedbox, remoteDir: "/home/vinit/done",
                                         existing: Set(items.map(\.name)), free: [], colliding: items)
    }
}
#endif
