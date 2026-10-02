#if DEBUG
import Foundation
import GoelCore

/// Sample previews, formats, playlists and links for the AddFlow snapshots.
@MainActor
enum AddFlowSamples {
    static let isoURL = "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso"
    static let pageURL = URL(string: "https://vimeo.com/76979871")!
    static let playlistURL = URL(string: "https://www.youtube.com/playlist?list=PLa1F2ddGya_-UvuAqHAksYnB0qL9yWDO6")!
    static let cookies = "sid=REDACTED; csrf=REDACTED; theme=dark; _ga=REDACTED; prefs=REDACTED"

    static let pastedLines = """
        \(isoURL)
        magnet:?xt=urn:btih:5c1a9d3e8f7b6a5c4d3e2f1a0b9c8d7e6f5a4b3c&dn=Sprite.Fright.2021.4K
        https://cdn.example.org/lectures/week[01-12].mp4
        https://stream.example.tv/live/master.m3u8
        """

    static var isoPreview: DownloadPreview {
        DownloadPreview(source: .url(URL(string: isoURL)!),
                        suggestedName: "ubuntu-24.04.1-live-server-amd64.iso",
                        totalBytes: 2_640_000_000, kind: .http)
    }

    /// The same release the sample list is already downloading.
    static var duplicatePreview: DownloadPreview {
        let url = "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso"
        return DownloadPreview(source: .url(URL(string: url)!),
                               suggestedName: "ubuntu-24.04.1-desktop-amd64.iso",
                               totalBytes: 4_700_000_000, kind: .http)
    }

    static var torrentPreview: DownloadPreview {
        let mb: Int64 = 1_000_000
        return DownloadPreview(
            source: .magnet("magnet:?xt=urn:btih:5c1a9d3e8f7b6a5c4d3e2f1a0b9c8d7e6f5a4b3c&dn=Sprite.Fright.2021.4K"),
            suggestedName: "Sprite.Fright.2021.4K",
            totalBytes: 9_412 * mb,
            files: [
                TransferFile(id: 0, path: "Sprite.Fright.2021.4K/Sprite.Fright.2021.2160p.mkv", length: 9_200 * mb),
                TransferFile(id: 1, path: "Sprite.Fright.2021.4K/Subs/English.srt", length: 84_000),
                TransferFile(id: 2, path: "Sprite.Fright.2021.4K/Sample/sample.mkv", length: 210 * mb),
                TransferFile(id: 3, path: "Sprite.Fright.2021.4K/poster.jpg", length: 1_800_000),
            ],
            kind: .torrent,
            note: "Found 38 peers. More files may appear once the download starts.")
    }

    static var unreachablePreview: DownloadPreview {
        DownloadPreview(source: .url(URL(string: "https://files.studio-partner.com/client-assets-2026.zip")!),
                        suggestedName: "client-assets-2026.zip",
                        totalBytes: nil, kind: .http,
                        note: "The server didn’t answer within 15 seconds.",
                        noteIsGenericUnreachable: true)
    }

    static var videoPagePreview: DownloadPreview {
        DownloadPreview(source: .url(pageURL), suggestedName: "Charge — Blender Open Movie.mp4",
                        totalBytes: nil, isEstimatedSize: true, kind: .http)
    }

    static var formats: [MediaFormat] {
        MediaFormatTable.parse("""
            [info] Available formats for 76979871:
            ID  EXT   RESOLUTION FPS CH |   FILESIZE   TBR PROTO | VCODEC        VBR ACODEC      ABR ASR MORE INFO
            --- ----- ---------- --- -- - --------- ----- ------ - ------------ ---- ---------- ---- --- ---------
            251 webm  audio only       2 |  17.20MiB  160k https | audio only        opus        160k 48k medium
            140 m4a   audio only       2 |  22.43MiB  130k https | audio only        mp4a.40.2   130k 44k medium
            18  mp4   640x360     30  2 |  98.78MiB  372k https | avc1.42001E  372k mp4a.40.2      0k 44k 360p
            22  mp4   1280x720    30  2 | 318.02MiB 1240k https | avc1.64001F 1240k mp4a.40.2   128k 44k 720p
            137 mp4   1920x1080   30    | 612.85MiB 1955k https | avc1.640028 1955k video only          1080p
            313 webm  3840x2160   30    |   1.80GiB 8600k https | vp9         8600k video only          2160p
            """)
    }

    static var playlist: PlaylistExpansion {
        let titles = [("Charge", 863), ("Sprite Fright", 629), ("Spring", 464), ("Coffee Run", 184),
                      ("Agent 327: Operation Barbershop", 231), ("Hero", 236), ("Cosmos Laundromat", 730),
                      ("Caminandes 3: Llamigos", 150)]
        return PlaylistExpansion(title: "Blender Open Movies", items: titles.enumerated().map { index, item in
            PlaylistItem(id: "v\(index)", title: item.0, url: "https://www.youtube.com/watch?v=v\(index)",
                         durationSeconds: item.1, index: index + 1)
        })
    }

    static let reviewLines = """
        https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso
        https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso
        https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-12.7.0-arm64-netinst.iso
        https://download.blender.org/demo/cycles/classroom.zip
        https://files.studio-partner.com/client-assets-2026.zip
        magnet:?xt=urn:btih:5c1a9d3e8f7b6a5c4d3e2f1a0b9c8d7e6f5a4b3c&dn=Sprite.Fright.2021.4K
        https://stream.example.tv/live/master.m3u8
        https://www.example.org/press/annual-report-2025.pdf
        """

    static func reviewItems(_ model: AppViewModel) -> [LinkReviewItem] {
        let sizes: [Int64?] = [2_640_000_000, 4_700_000_000, 526_000_000, 141_000_000, 1_400_000_000, nil, nil, 8_400_000]
        return model.reviewItems(for: reviewLines).enumerated().map { index, item in
            var copy = item
            copy.sizeRequested = true
            copy.sizeResolved = index != 5
            copy.size = index < sizes.count ? sizes[index] : nil
            return copy
        }
    }

    static func items(_ model: AppViewModel, from urls: [String]) -> [LinkReviewItem] {
        model.reviewItems(for: urls.joined(separator: "\n")).enumerated().map { index, item in
            var copy = item
            copy.sizeRequested = true
            copy.sizeResolved = true
            copy.size = Int64(28 + index * 61) * 1_000_000
            return copy
        }
    }

    static var grabbedLinks: [GrabbedLink] {
        let base = "https://download.blender.org/demo/"
        let names = ["classroom.zip", "barbershop_interior.zip", "junk_shop.zip", "splash-pokedstudio.zip",
                     "wanderer.zip", "lone-monk.zip", "blender-2.79-splash.zip", "cycles-benchmark.zip",
                     "sprite_fright_trailer.mp4", "charge_teaser.webm", "spring_trailer.mov",
                     "agent327_still.png", "coffee_run_poster.jpg", "hero_frame.webp",
                     "demo-files-readme.pdf", "release-notes.pdf", "blender-4.2.iso"]
        return names.compactMap { name in
            let url = base + name
            guard let category = LinkExtractor.category(for: URL(string: url)!) else { return nil }
            return GrabbedLink(url: url, category: category)
        }
    }
}
#endif
