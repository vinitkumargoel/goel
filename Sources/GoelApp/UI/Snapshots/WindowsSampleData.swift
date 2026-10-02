#if DEBUG
import SwiftUI
import GoelCore

/// Sample state the Windows snapshots need beyond `StudioSampleData`: conversion jobs, SFTP
/// transfers, statistics, history entries and RSS articles, built from public model types.
@MainActor
enum WindowsSampleData {

    enum JobSample { case running, finished, failed, queued, stalled, cancelled, cancelling, stuck }

    static func job(_ sample: JobSample) -> MediaJobCenter.Job {
        let movies = URL(fileURLWithPath: "\(StudioSampleData.downloads)/Video")
        let now = Date()
        switch sample {
        case .running:
            return MediaJobCenter.Job(input: movies.appendingPathComponent("Charge.webm"), kind: .convert(ext: "mp4"),
                                      state: .running, totalSeconds: 600, processedSeconds: 330, speed: 2.4,
                                      bytesWritten: 182_000_000, lastAdvance: now, startedAt: now.addingTimeInterval(-140))
        case .finished:
            return MediaJobCenter.Job(input: movies.appendingPathComponent("Sprite Fright.mkv"),
                                      kind: .extractAudio(format: .m4a),
                                      state: .finished(movies.appendingPathComponent("Sprite Fright.m4a"),
                                                       usedStreamCopy: true),
                                      startedAt: now.addingTimeInterval(-48), finishedAt: now.addingTimeInterval(-6))
        case .failed:
            return MediaJobCenter.Job(input: movies.appendingPathComponent("Spring.mkv"), kind: .convert(ext: "mp4"),
                                      state: .failed("ffmpeg exited with code 1"),
                                      log: "Stream #0:1: Audio: truehd\n[mp4 @ 0x7f] Could not find tag for codec truehd\nConversion failed!")
        case .queued:
            return MediaJobCenter.Job(input: movies.appendingPathComponent("Cosmos.S01E04.mkv"), kind: .convert(ext: "mov"))
        case .stalled:
            return MediaJobCenter.Job(input: movies.appendingPathComponent("Tears of Steel.webm"), kind: .convert(ext: "mp4"),
                                      state: .running, totalSeconds: 734, processedSeconds: 120,
                                      lastAdvance: now.addingTimeInterval(-340), startedAt: now.addingTimeInterval(-600))
        case .cancelled:
            return MediaJobCenter.Job(input: movies.appendingPathComponent("Agent 327.mkv"), kind: .convert(ext: "mp4"),
                                      state: .cancelled, removedPartial: true)
        case .cancelling:
            return MediaJobCenter.Job(input: movies.appendingPathComponent("Caminandes.mkv"), kind: .convert(ext: "mp4"),
                                      state: .cancelling, totalSeconds: 146, processedSeconds: 40,
                                      cancelRequestedAt: now.addingTimeInterval(-1))
        case .stuck:
            return MediaJobCenter.Job(input: movies.appendingPathComponent("Glass Half.mkv"), kind: .convert(ext: "mp4"),
                                      state: .cancelling, startedAt: now.addingTimeInterval(-400),
                                      cancelRequestedAt: now.addingTimeInterval(-60))
        }
    }

    static var stats: TransferStats {
        var perDay: [String: TransferStats.DayTotals] = [:]
        let gb = StudioSampleData.gb
        let downs: [Int64] = [22, 31, 18, 40, 12, 9, 27, 35, 44, 19, 26, 33, 48, 38]
        let ups: [Int64] = [3, 4, 2, 5, 1, 1, 3, 4, 6, 2, 3, 4, 5, 4]
        for offset in 0..<14 {
            guard let day = Calendar.current.date(byAdding: .day, value: -(13 - offset), to: Date()) else { continue }
            if offset == 5 { continue }
            perDay[TransferStats.dayKey(for: day)] = .init(down: downs[offset] * gb, up: ups[offset] * gb)
        }
        return TransferStats(totalDownloadedBytes: 1_840 * gb, totalUploadedBytes: 312 * gb,
                             completedCount: 1_204, perDay: perDay)
    }

    static var historyItems: [HistoryPresentation.Item] {
        let now = Date()
        let calendar = Calendar.current
        func day(_ offset: Int, _ hour: Int, _ minute: Int) -> Date {
            let base = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
            return offset == 0 ? min(date, now.addingTimeInterval(-Double(60 * (24 - hour)))) : date
        }
        let downloads = StudioSampleData.downloads
        let rows: [(String, String, DownloadKind, Int64, Date, Bool)] = [
            ("BigBuckBunny-1080p.mp4", "https://test-streams.mux.dev/bbb/master.m3u8", .hls, 340_000_000, day(0, 20, 12), true),
            ("Q3-board-pack.pdf", "https://drive.company.com/files/Q3-board-pack.pdf", .http, 8_400_000, day(0, 18, 40), true),
            ("debian-12.6.0-amd64-DVD-1.iso", "magnet:?xt=urn:btih:9a8b7c6d5e4f", .torrent, 3_700_000_000, day(0, 18, 20), true),
            ("Blender-4.2.3-macos-arm64.dmg", "https://download.blender.org/release/Blender4.2/blender-4.2.3-macos-arm64.dmg", .http, 398_000_000, day(1, 8, 47), false),
            ("Field Recordings Vol. 2.flac", "https://archive.org/download/field-2/field-recordings-vol-2.flac", .http, 1_100_000_000, day(1, 7, 15), true),
            ("project-backup-2026-06.tar.zst", "sftp://nas.home/srv/backups/project-backup-2026-06.tar.zst", .sftp, 2_100_000_000, day(4, 22, 10), true),
            ("Figma-125.9.dmg", "https://desktop.figma.com/mac-arm/Figma-125.9.dmg", .http, 182_000_000, day(5, 9, 2), true),
            ("ubuntu-24.04-live-server-amd64.iso", "https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso", .http, 2_700_000_000, day(12, 14, 30), true),
        ]
        return rows.enumerated().map { index, row in
            let entry = HistoryEntry(id: UUID(uuidString: String(format: "5D1A0000-0000-4000-9000-%012d", index + 1)) ?? UUID(),
                                     name: row.0, locator: row.1, kind: row.2, totalBytes: row.3,
                                     savePath: "\(downloads)/\(row.0)", completedAt: row.4)
            return HistoryPresentation.Item(entry: entry,
                                            type: FileType.classify(fileName: row.0, isTorrent: row.2 == .torrent),
                                            exists: row.5)
        }
    }

    static let linuxFeed = RSSFeed(id: UUID(uuidString: "5D1A0000-0000-4000-A000-000000000001") ?? UUID(),
                                   url: "https://distrowatch.example/releases.rss", titlePattern: "ubuntu|fedora",
                                   mustNotContain: "beta|rc", saveDirectory: "\(StudioSampleData.downloads)/Disc images/Linux",
                                   tag: "linux", name: "Linux ISO releases")
    static let blenderFeed = RSSFeed(id: UUID(uuidString: "5D1A0000-0000-4000-A000-000000000002") ?? UUID(),
                                     url: "https://studio.blender.example/films.rss", name: "Blender Studio")
    static let pausedFeed = RSSFeed(id: UUID(uuidString: "5D1A0000-0000-4000-A000-000000000003") ?? UUID(),
                                    url: "https://podcasts.example.org/weekly.xml", enabled: false)

    static var linuxArticles: [RSSItem] {
        [
            RSSItem(title: "Ubuntu 24.10 “Oracular Oriole” released",
                    link: "https://ubuntu.example/blog/24-10",
                    enclosureURL: "https://releases.ubuntu.com/24.10/ubuntu-24.10-desktop-amd64.iso",
                    summary: "<p>Ubuntu 24.10 ships with GNOME 47, Linux 6.11 and a new installer.</p><p>Desktop and server images are available for amd64 and arm64.</p>",
                    published: "2h ago"),
            RSSItem(title: "Debian 12.7 point release", link: "https://debian.example/news/12.7", published: "Yesterday"),
            RSSItem(title: "Fedora 41 Beta is available", link: "https://fedora.example/41-beta",
                    enclosureURL: "https://download.fedora.example/41/Fedora-Workstation-41-beta.iso", published: "2 days ago"),
            RSSItem(title: "Fedora Workstation 40 respin", link: "https://fedora.example/40-respin", published: "3 days ago"),
            RSSItem(title: "Linux Mint 22 “Wilma” Cinnamon", link: "https://mint.example/22", published: "4 days ago"),
            RSSItem(title: "Arch Linux 2026.10.01 ISO", link: "https://arch.example/iso", guid: "arch-2026-10", published: "1 Oct"),
        ]
    }

    static func rssData(selectArticle: Bool = true) -> RSSReaderData {
        let articles = linuxArticles
        return RSSReaderData(feeds: [linuxFeed, blenderFeed, pausedFeed],
                             articles: [linuxFeed.id: articles,
                                        blenderFeed.id: [RSSItem(title: "Wing It! — production files"),
                                                         RSSItem(title: "Sprite Fright 4K master")]],
                             readKeys: [articles[5].key, articles[4].key],
                             selectedFeed: linuxFeed.id,
                             selectedArticle: selectArticle ? articles[0].key : nil)
    }

    /// A countdown stopped at 30 s, never ticking and never acting.
    static func countdown(_ intent: DrainIntent = .sleep, remaining: Int = 30) -> AutoShutdownCountdown {
        let countdown = AutoShutdownCountdown(seconds: 60, autoTick: false) { _ in }
        countdown.begin(intent)
        for _ in 0..<(60 - remaining) { countdown.tick() }
        return countdown
    }
}
#endif
