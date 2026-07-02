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

    /// Resolve the yt-dlp binary. A packaged build carries its own copy inside
    /// `Contents/Resources/` (see `Scripts/fetch_ytdlp.sh`), so the feature works
    /// on a machine with nothing installed; we prefer that. Dev builds (run via
    /// `swift run`, no bundle copy) and users who keep their own newer yt-dlp
    /// fall back to the common install locations (Homebrew arm64/intel, pipx/pip).
    static var executable: URL? {
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("yt-dlp", isDirectory: false).path {
            candidates.append(bundled)
        }
        candidates += [
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

    /// Fetch subtitles for `pageURL` into `directory`, named to sit beside the
    /// video (`<baseName>.<lang>.<ext>`). Runs yt-dlp with `--skip-download` so no
    /// media is re-fetched. `languages` is a comma/space list of codes; when
    /// `includeAuto` is set, machine captions are accepted as a fallback. Returns
    /// the number of subtitle files written (0 on failure or none available).
    @discardableResult
    static func downloadSubtitles(pageURL: URL, into directory: String, baseName: String,
                                  languages: String, includeAuto: Bool) async -> Int {
        guard let executable,
              let scheme = pageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return 0 }

        let langs = languages
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        let langArg = langs.isEmpty ? "en" : langs.joined(separator: ",")
        let template = (directory as NSString).appendingPathComponent(baseName + ".%(ext)s")

        var args = ["--skip-download", "--no-playlist", "--no-warnings", "--write-subs"]
        if includeAuto { args.append("--write-auto-subs") }
        args += ["--sub-langs", langArg, "-o", template, pageURL.absoluteString]

        // Snapshot the directory so we can count only the subtitle files this run
        // produced (yt-dlp exits 0 even when a video simply has no subtitles).
        let fm = FileManager.default
        let before = Set((try? fm.contentsOfDirectory(atPath: directory)) ?? [])

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return 0 }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if process.isRunning { process.terminate() }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return 0 }
        let after = Set((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
        let subExtensions = ["vtt", "srt", "ass", "ssa", "lrc"]
        return after.subtracting(before).filter {
            subExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }.count
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
