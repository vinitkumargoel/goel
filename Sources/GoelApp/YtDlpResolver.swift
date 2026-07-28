import Foundation
import GoelCore

/// Optional hand-off to `yt-dlp` for video-site pages: resolves a page URL to a direct media
/// stream the normal engines can download. Never runs unless the user explicitly asks.
enum YtDlpResolver {

    struct Resolved {
        var title: String
        var mediaURL: URL
        var fileExtension: String?
    }

    /// Resolve the yt-dlp binary, preferring the packaged copy in `Contents/Resources/` so the
    /// feature works with nothing installed. Dev builds fall back to the common install locations.
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

    /// The outcome of resolving a page to a direct stream, distinguishing a genuine failure (which
    /// carries yt-dlp's own explanation) from the caller walking away mid-run, which stays silent.
    enum ResolveOutcome: Sendable {
        case resolved(Resolved)
        /// Sheet dismissed / Cancel — no toast, no stale UI.
        case cancelled
        case failed(String)
    }

    /// Ask yt-dlp for the best *muxed* format of the media behind `url`. Returns a reason rather than
    /// a bare nil: yt-dlp's own line is the only thing telling the user which remedy applies.
    static func resolveMedia(_ url: URL, formatSelector: String? = nil) async -> ResolveOutcome {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failed("That isn’t a web page address.")
        }
        if Task.isCancelled { return .cancelled }

        let result: ToolRun
        do {
            // Watchdog: some extractors hang on slow sites; kill after 45 s.
            result = try await run(["-j", "--no-playlist", "--no-warnings",
                                    "-f", formatSelector ?? "b", url.absoluteString],
                                   timeoutSeconds: 45)
        } catch LaunchFailure.notInstalled {
            return .failed("yt-dlp isn’t available, so Goel° can’t resolve that page.")
        } catch {
            return .failed("Couldn’t start yt-dlp.")
        }
        if Task.isCancelled { return .cancelled }
        guard result.status == 0 else {
            return .failed(message(from: result.stderr,
                                   fallback: "yt-dlp couldn’t resolve that page."))
        }
        guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let mediaString = object["url"] as? String,
              let media = URL(string: mediaString),
              ["http", "https"].contains(media.scheme?.lowercased() ?? "") else {
            // Exit 0 but no direct stream: usually a format that needs an ffmpeg
            // merge, which this app can't download as a single URL.
            return .failed("yt-dlp didn’t report a single downloadable stream for that page.")
        }
        return .resolved(Resolved(
            title: (object["title"] as? String) ?? "video",
            mediaURL: media,
            fileExtension: object["ext"] as? String))
    }

    /// Nil-on-anything-wrong shim over ``resolveMedia(_:formatSelector:)`` for callers with nowhere
    /// to show a reason. Prefer the outcome-returning form — discarding it makes failures undiagnosable.
    static func resolve(_ url: URL, formatSelector: String? = nil) async -> Resolved? {
        guard case .resolved(let resolved) = await resolveMedia(url, formatSelector: formatSelector) else {
            return nil
        }
        return resolved
    }

    /// The outcome of a subtitle fetch, separating "wrote N files" from the common "this video has
    /// none" and a genuine failure, so the caller can stay quiet on `none` but surface `failed`.
    enum SubtitleOutcome: Sendable {
        case downloaded(Int)
        case none
        case failed(String)
    }

    /// Fetch subtitles for `pageURL` into `directory`, named to sit beside the video. Runs with
    /// `--skip-download`; `includeAuto` accepts machine captions as a fallback.
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

    // MARK: - Shared process plumbing

    /// The captured result of one yt-dlp invocation.
    private struct ToolRun {
        var stdout: Data
        var stderr: Data
        var status: Int32
    }

    /// Why a yt-dlp run could not even be attempted.
    private enum LaunchFailure: Error {
        case notInstalled
        case couldNotLaunch(String)
    }

    /// Run yt-dlp with `arguments`, capturing both streams, with a watchdog and cooperative
    /// cancellation. Both pipes drain concurrently or a large listing deadlocks on a full pipe.
    private static func run(_ arguments: [String], timeoutSeconds: UInt64) async throws -> ToolRun {
        guard let executable else { throw LaunchFailure.notInstalled }
        let process = Process()
        let outPipe = Pipe(), errPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw LaunchFailure.couldNotLaunch(error.localizedDescription)
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            if process.isRunning { process.terminate() }
        }
        let errHandle = errPipe.fileHandleForReading
        let errTask = Task.detached { errHandle.readDataToEndOfFile() }
        let outData: Data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        let errData = await errTask.value
        watchdog.cancel()
        return ToolRun(stdout: outData, stderr: errData, status: process.terminationStatus)
    }

    /// The last meaningful line of yt-dlp's stderr, or `fallback`. yt-dlp puts the actionable
    /// sentence last, and showing that beats a generic failure toast.
    private static func message(from stderr: Data, fallback: String) -> String {
        let text = String(data: stderr, encoding: .utf8) ?? ""
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        guard let line, !line.isEmpty else { return fallback }
        return String(line.suffix(200))
    }

    // MARK: - Format listing

    /// The outcome of asking yt-dlp what renditions a page offers.
    enum FormatListOutcome: Sendable {
        case formats([MediaFormat])
        case failed(String)
    }

    /// List the renditions behind `url` via `yt-dlp -F`, parsed into pickable rows. Unrecognised rows
    /// are dropped rather than guessed at, so a layout change degrades to a shorter list.
    static func listFormats(_ url: URL) async -> FormatListOutcome {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failed("That isn’t a web page address.")
        }
        let result: ToolRun
        do {
            result = try await run(["-F", "--no-playlist", "--no-warnings", url.absoluteString],
                                   timeoutSeconds: 45)
        } catch LaunchFailure.notInstalled {
            return .failed("yt-dlp isn’t available, so Goel° can’t list the available qualities.")
        } catch {
            return .failed("Couldn’t start yt-dlp.")
        }
        // Sheet dismissed / Cancel: the terminated process exits non-zero, so bail
        // quietly instead of surfacing a stale error.
        if Task.isCancelled { return .formats([]) }
        guard result.status == 0 else {
            return .failed(message(from: result.stderr,
                                   fallback: "yt-dlp couldn’t read that page."))
        }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        let formats = MediaFormatTable.parse(text)
        guard !formats.isEmpty else {
            return .failed("yt-dlp didn’t report any downloadable formats for that page.")
        }
        return .formats(formats)
    }

    // MARK: - Playlist / channel expansion

    /// The outcome of expanding a playlist or channel URL into its items.
    enum PlaylistOutcome: Sendable {
        case expanded(PlaylistExpansion)
        /// The URL resolved to a single video — the caller should fall back to the
        /// ordinary one-URL add path rather than show an empty checklist.
        case notAPlaylist
        case failed(String)
    }

    /// Enumerate a playlist/channel with `--flat-playlist -J` — one request rather than 501, at the
    /// cost of absent per-item metadata. The 4-minute watchdog suits a legitimately large channel.
    static func expandPlaylist(_ url: URL) async -> PlaylistOutcome {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failed("That isn’t a web page address.")
        }
        let result: ToolRun
        do {
            result = try await run(["--flat-playlist", "-J", "--no-warnings", url.absoluteString],
                                   timeoutSeconds: 240)
        } catch LaunchFailure.notInstalled {
            return .failed("yt-dlp isn’t available, so Goel° can’t list what’s in that playlist.")
        } catch {
            return .failed("Couldn’t start yt-dlp.")
        }
        if Task.isCancelled { return .notAPlaylist }
        guard result.status == 0 else {
            return .failed(message(from: result.stderr,
                                   fallback: "yt-dlp couldn’t read that playlist."))
        }
        guard let expansion = PlaylistExpander.parseFlatPlaylist(result.stdout) else {
            return .notAPlaylist
        }
        guard !expansion.items.isEmpty else {
            return .failed("That playlist doesn’t list any downloadable items.")
        }
        return .expanded(expansion)
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
