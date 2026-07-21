import Foundation
import GoelCore

/// Optional hand-off to a user-installed `yt-dlp` for video-site pages: given
/// a page URL, it resolves the direct media stream (plus a human title) that
/// the normal engines can download. Nothing here runs unless a yt-dlp is
/// actually present and the user explicitly clicks the resolve button; the app
/// never downloads the tool itself. Standard builds do not bundle it either
/// (see `BUNDLE_YTDLP` in `Scripts/build_app.sh`), so in practice this means a
/// copy the user installed — the button hides entirely when none is found.
enum YtDlpResolver {

    struct Resolved {
        var title: String
        var mediaURL: URL
        var fileExtension: String?
    }

    /// Resolve the yt-dlp binary. A build made with `BUNDLE_YTDLP=1` carries its
    /// own copy inside `Contents/Resources/` (see `Scripts/fetch_ytdlp.sh`) and we
    /// prefer that when present. Standard builds, dev runs (`swift run`), and users
    /// who keep their own newer yt-dlp fall through to the common install
    /// locations (Homebrew arm64/intel, pipx/pip).
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
        if Task.isCancelled { return nil }

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
        let data: Data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let output = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: output)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        watchdog.cancel()
        // Caller walked away (sheet dismissed / Cancel): stay silent, no stale UI.
        if Task.isCancelled { return nil }
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

    /// The outcome of a subtitle fetch, distinguishing "wrote N files" from the
    /// legitimately-common "this video has none" and a genuine failure (yt-dlp
    /// missing, launch error, or a non-zero exit) so the caller can stay quiet on
    /// `none` but surface `failed`.
    enum SubtitleOutcome: Sendable {
        case downloaded(Int)
        case none
        case failed(String)
    }

    /// Fetch subtitles for `pageURL` into `directory`, named to sit beside the
    /// video (`<baseName>.<lang>.<ext>`). Runs yt-dlp with `--skip-download` so no
    /// media is re-fetched. `languages` is a comma/space list of codes; when
    /// `includeAuto` is set, machine captions are accepted as a fallback.
    @discardableResult
    static func downloadSubtitles(pageURL: URL, into directory: String, baseName: String,
                                  languages: String, includeAuto: Bool) async -> SubtitleOutcome {
        guard let executable else { return .failed("yt-dlp not found.") }
        guard let scheme = pageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return .failed("Unsupported URL.") }
        if Task.isCancelled { return .none }

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
        let errPipe = Pipe()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do { try process.run() } catch { return .failed("Couldn’t launch yt-dlp: \(error.localizedDescription)") }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if process.isRunning { process.terminate() }
        }
        let errData: Data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        watchdog.cancel()
        // Caller walked away (sheet dismissed / Cancel): the terminated process
        // exits non-zero, so bail quietly instead of surfacing a stale toast.
        if Task.isCancelled { return .none }
        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(msg?.isEmpty == false ? String(msg!.suffix(200)) : "yt-dlp couldn’t fetch subtitles.")
        }
        let after = Set((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
        let subExtensions = ["vtt", "srt", "ass", "ssa", "lrc"]
        let count = after.subtracting(before).filter {
            subExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }.count
        return count > 0 ? .downloaded(count) : .none
    }

    /// Build the add-flow preview for a resolved stream. HLS manifests route to
    /// the HLS engine; direct files to HTTP.
    static func preview(for resolved: Resolved) -> DownloadPreview? {
        guard let source = DownloadSource.parse(resolved.mediaURL.absoluteString) else { return nil }
        let ext = resolved.fileExtension ?? (source.kind == .hls ? "mp4" : "bin")
        let name = PathSafety.sanitizedName("\(resolved.title).\(ext)", fallback: "video.\(ext)")
        return DownloadPreview(
            source: source, suggestedName: name, totalBytes: nil,
            isEstimatedSize: source.kind == .hls, kind: source.kind,
            note: "Resolved by yt-dlp — the stream URL may expire; start the download soon.")
    }
}
