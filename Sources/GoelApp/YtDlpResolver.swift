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
    ///
    /// `formatSelector` is a yt-dlp format id chosen by the user in
    /// ``MediaFormatPicker``. When nil the default `b` (best muxed) is used —
    /// deliberately not a guess at an id, because an id that does not exist for
    /// this video makes yt-dlp fail outright rather than fall back.
    static func resolve(_ url: URL, formatSelector: String? = nil) async -> Resolved? {
        guard let executable,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        if Task.isCancelled { return nil }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["-j", "--no-playlist", "--no-warnings",
                             "-f", formatSelector ?? "b", url.absoluteString]
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

    /// Run yt-dlp with `arguments`, capturing both streams, with a watchdog and
    /// cooperative cancellation. Both pipes are drained concurrently — a listing
    /// large enough to fill the stdout pipe while stderr also has content would
    /// otherwise deadlock, which is exactly what a 3 000-video channel does.
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

    /// The last meaningful line of yt-dlp's stderr, or `fallback`. yt-dlp puts the
    /// actionable sentence last ("Video unavailable", "Sign in to confirm…"), and
    /// showing that beats a generic failure toast.
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

    /// List the renditions behind `url` via `yt-dlp -F`, parsed into pickable rows.
    ///
    /// This is the metadata pass behind ``MediaFormatPicker``: one cheap call, no
    /// media fetched. The table (rather than `--dump-json`) is what gets parsed —
    /// see ``MediaFormatTable`` for why — and rows the parser doesn't recognise
    /// are dropped rather than guessed at, so a layout change degrades to a
    /// shorter list instead of wrong sizes.
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

    /// Enumerate the items of a playlist/channel URL with `--flat-playlist -J`.
    ///
    /// `--flat-playlist` is what keeps this affordable: yt-dlp lists the entries
    /// without visiting each video page, so a 500-item playlist is one request
    /// rather than 501. The trade is that per-item metadata (duration, exact
    /// size) is often absent — hence the optional fields on ``PlaylistItem``.
    ///
    /// The 4-minute watchdog is generous on purpose: a large channel legitimately
    /// takes minutes to page through, and killing it early would look like the
    /// feature is broken on exactly the inputs it exists for.
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
