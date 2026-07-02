import Foundation
import GoelCore

/// Optional hand-off to a user-installed `yt-dlp` for video-site pages: given
/// a page URL, it resolves the direct media stream (plus a human title) that
/// the normal engines can download. Nothing here runs unless the user has
/// installed yt-dlp themselves and explicitly clicks the resolve button —
/// the app never downloads or bundles the tool.
enum YtDlpResolver {

    struct Resolved {
        var title: String
        var mediaURL: URL
        var fileExtension: String?
    }

    /// Common install locations (Homebrew arm64/intel, pipx/pip --user).
    static var executable: URL? {
        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            NSHomeDirectory() + "/.local/bin/yt-dlp",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    static var isAvailable: Bool { executable != nil }

    /// Ask yt-dlp for the best *muxed* format (a single downloadable URL — no
    /// ffmpeg merge step) of the media behind `url`. Nil on any failure.
    static func resolve(_ url: URL) async -> Resolved? {
        guard let executable,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["-j", "--no-playlist", "--no-warnings",
                             "-f", "b", url.absoluteString]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Watchdog: some extractors hang on slow sites; kill after 45 s.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if process.isRunning { process.terminate() }
        }
        let data: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: output)
            }
        }
        watchdog.cancel()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mediaString = object["url"] as? String,
              let media = URL(string: mediaString),
              ["http", "https"].contains(media.scheme?.lowercased() ?? "") else { return nil }
        return Resolved(
            title: (object["title"] as? String) ?? "video",
            mediaURL: media,
            fileExtension: object["ext"] as? String)
    }

    /// Build the add-flow preview for a resolved stream. HLS manifests route to
    /// the HLS engine; direct files to HTTP.
    static func preview(for resolved: Resolved) -> DownloadPreview? {
        guard let source = DownloadSource.parse(resolved.mediaURL.absoluteString) else { return nil }
        let ext = resolved.fileExtension ?? (source.kind == .hls ? "mp4" : "bin")
        let name = DownloadTask.sanitizedName("\(resolved.title).\(ext)", fallback: "video.\(ext)")
        return DownloadPreview(
            source: source, suggestedName: name, totalBytes: nil,
            isEstimatedSize: source.kind == .hls, kind: source.kind,
            note: "Resolved by yt-dlp — the stream URL may expire; start the download soon.")
    }
}
