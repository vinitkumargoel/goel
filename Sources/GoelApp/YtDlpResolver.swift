import Foundation
import GoelCore

enum YtDlpResolver {

    struct Resolved {
        var title: String
        var mediaURL: URL
        var fileExtension: String?
    }

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

    enum ResolveOutcome: Sendable {
        case resolved(Resolved)
        case cancelled
        case failed(String)
    }

    static func resolveMedia(_ url: URL, formatSelector: String? = nil) async -> ResolveOutcome {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failed(L10n.t("That isn’t a web page address."))
        }
        if Task.isCancelled { return .cancelled }

        let result: ToolRun
        do {
            result = try await run(["-j", "--no-playlist", "--no-warnings",
                                    "-f", formatSelector ?? "b", url.absoluteString],
                                   timeoutSeconds: 45)
        } catch LaunchFailure.notInstalled {
            return .failed("yt-dlp isn’t available, so Goel° can’t resolve that page.")
        } catch {
            return .failed(L10n.t("Couldn’t start yt-dlp."))
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
            return .failed("yt-dlp didn’t report a single downloadable stream for that page.")
        }
        return .resolved(Resolved(
            title: (object["title"] as? String) ?? "video",
            mediaURL: media,
            fileExtension: object["ext"] as? String))
    }

    static func resolve(_ url: URL, formatSelector: String? = nil) async -> Resolved? {
        guard case .resolved(let resolved) = await resolveMedia(url, formatSelector: formatSelector) else {
            return nil
        }
        return resolved
    }

    enum SubtitleOutcome: Sendable {
        case downloaded(Int)
        case none
        case failed(String)
    }

    @discardableResult
    static func downloadSubtitles(pageURL: URL, into directory: String, baseName: String,
                                  languages: String, includeAuto: Bool) async -> SubtitleOutcome {
        guard let executable else { return .failed("yt-dlp not found.") }
        guard let scheme = pageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return .failed(L10n.t("Unsupported URL.")) }
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

        // yt-dlp exits 0 even when a video has no subtitles, so count only what this run added.
        let fm = FileManager.default
        let before = Set((try? fm.contentsOfDirectory(atPath: directory)) ?? [])

        let process = Process()
        let errPipe = Pipe()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do { try process.run() } catch {
            return .failed(L10n.t("Couldn’t launch yt-dlp: %@", error.localizedDescription))
        }
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
        // Must precede the status guard: a cancelled run's terminated process exits non-zero.
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

    private struct ToolRun {
        var stdout: Data
        var stderr: Data
        var status: Int32
    }

    private enum LaunchFailure: Error {
        case notInstalled
        case couldNotLaunch(String)
    }

    /// Both pipes must drain concurrently or a large listing deadlocks on a full pipe.
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

    private static func message(from stderr: Data, fallback: String) -> String {
        let text = String(data: stderr, encoding: .utf8) ?? ""
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        guard let line, !line.isEmpty else { return fallback }
        return String(line.suffix(200))
    }

    enum FormatListOutcome: Sendable {
        case formats([MediaFormat])
        case failed(String)
    }

    static func listFormats(_ url: URL) async -> FormatListOutcome {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failed(L10n.t("That isn’t a web page address."))
        }
        let result: ToolRun
        do {
            result = try await run(["-F", "--no-playlist", "--no-warnings", url.absoluteString],
                                   timeoutSeconds: 45)
        } catch LaunchFailure.notInstalled {
            return .failed("yt-dlp isn’t available, so Goel° can’t list the available qualities.")
        } catch {
            return .failed(L10n.t("Couldn’t start yt-dlp."))
        }
        // Must precede the status guard: a cancelled run's terminated process exits non-zero.
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

    enum PlaylistOutcome: Sendable {
        case expanded(PlaylistExpansion)
        case notAPlaylist
        case failed(String)
    }

    /// 240s watchdog: a legitimately large channel takes minutes to enumerate.
    static func expandPlaylist(_ url: URL) async -> PlaylistOutcome {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failed(L10n.t("That isn’t a web page address."))
        }
        let result: ToolRun
        do {
            result = try await run(["--flat-playlist", "-J", "--no-warnings", url.absoluteString],
                                   timeoutSeconds: 240)
        } catch LaunchFailure.notInstalled {
            return .failed("yt-dlp isn’t available, so Goel° can’t list what’s in that playlist.")
        } catch {
            return .failed(L10n.t("Couldn’t start yt-dlp."))
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
            return .failed(L10n.t("That playlist doesn’t list any downloadable items."))
        }
        return .expanded(expansion)
    }

    static func preview(for resolved: Resolved) -> DownloadPreview? {
        guard let source = DownloadSource.parse(resolved.mediaURL.absoluteString) else { return nil }
        let ext = resolved.fileExtension ?? (source.kind == .hls ? "mp4" : "bin")
        let name = PathSafety.sanitizedName("\(resolved.title).\(ext)", fallback: "video.\(ext)")
        return DownloadPreview(
            source: source, suggestedName: name, totalBytes: nil,
            isEstimatedSize: source.kind == .hls, kind: source.kind,
            note: L10n.t("Resolved by yt-dlp — the stream URL may expire; start the download soon."))
    }
}
