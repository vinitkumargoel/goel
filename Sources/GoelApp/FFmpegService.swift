import Foundation
import GoelCore

/// Optional hand-off to a user-installed `ffmpeg` for post-download media work:
/// remuxing/converting a finished video and extracting its audio track. Nothing
/// here runs unless ffmpeg is actually present — the app neither bundles nor
/// downloads it, so the ~22 MB binary never bloats the release. Menu actions
/// that need it stay hidden when it is missing.
enum FFmpegService {

    /// Locate the ffmpeg binary. Honours an explicit override path first, then a
    /// copy bundled beside the app (if a build ever ships one), then the common
    /// Homebrew / pip install locations. Returns nil when nothing is found.
    static func executable(override: String = "") -> URL? {
        var candidates: [String] = []
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        // The override path comes from the settings DB (same-user-writable). Only
        // accept it if it's a concrete absolute non-interpreter executable — never
        // a relative $PATH name or a shell/script interpreter, which would turn a
        // "Convert"/"Extract Audio" click into arbitrary code execution. Mirrors
        // the guard AntivirusScanner already applies to its equivalent setting.
        if !trimmed.isEmpty, ProcessSafety.isSafeExecutable(trimmed) { candidates.append(trimmed) }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("ffmpeg", isDirectory: false).path {
            candidates.append(bundled)
        }
        candidates += [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            NSHomeDirectory() + "/.local/bin/ffmpeg",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    static func isAvailable(override: String = "") -> Bool { executable(override: override) != nil }

    /// A finished conversion: the produced file, or a human-readable failure.
    enum Outcome: Sendable {
        case success(URL)
        case failure(String)
    }

    /// Container/format targets offered in the UI, each with the extension and the
    /// ffmpeg codec arguments that produce it.
    enum AudioFormat: String, CaseIterable, Sendable {
        case mp3, m4a, flac, wav
        var ffmpegArgs: [String] {
            switch self {
            case .mp3:  return ["-vn", "-acodec", "libmp3lame", "-q:a", "2"]
            case .m4a:  return ["-vn", "-acodec", "aac", "-b:a", "192k"]
            case .flac: return ["-vn", "-acodec", "flac"]
            case .wav:  return ["-vn", "-acodec", "pcm_s16le"]
            }
        }
    }

    /// Convert `input` into a sibling file with extension `ext` (container change
    /// / remux+transcode as ffmpeg sees fit). Never overwrites the source.
    static func convert(input: URL, toExtension ext: String, override: String = "") async -> Outcome {
        let output = uniqueSibling(of: input, extension: ext)
        return await run(input: input, output: output,
                         extraArgs: [], override: override)
    }

    /// Extract the audio track of `input` into a sibling file of the chosen format.
    static func extractAudio(input: URL, format: AudioFormat, override: String = "") async -> Outcome {
        let output = uniqueSibling(of: input, extension: format.rawValue)
        return await run(input: input, output: output,
                         extraArgs: format.ffmpegArgs, override: override)
    }

    // MARK: - Process plumbing

    private static func run(input: URL, output: URL, extraArgs: [String], override: String) async -> Outcome {
        guard let exe = executable(override: override) else {
            return .failure("ffmpeg not found — install it (e.g. `brew install ffmpeg`).")
        }
        guard FileManager.default.isReadableFile(atPath: input.path) else {
            return .failure("The source file is missing.")
        }
        let process = Process()
        process.executableURL = exe
        // Don't hand ffmpeg the app's full environment (mirrors AntivirusScanner).
        process.environment = ProcessSafety.minimalEnvironment
        // -y: the output name is already unique, but be explicit. -nostdin so a
        // prompt can never hang the process. -loglevel error keeps stderr small.
        process.arguments = ["-nostdin", "-loglevel", "error", "-y",
                             "-i", input.path] + extraArgs + [output.path]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return .failure("Couldn't launch ffmpeg: \(error.localizedDescription)")
        }
        // Watchdog: kill a wedged transcode after 30 minutes.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            if process.isRunning { process.terminate() }
        }
        let errData: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: data)
            }
        }
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)   // don't leave a partial
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(msg?.isEmpty == false ? String(msg!.suffix(200)) : "ffmpeg failed.")
        }
        return .success(output)
    }

    /// A never-clobber sibling path: `name.ext`, then `name (1).ext`, …
    private static func uniqueSibling(of input: URL, extension ext: String) -> URL {
        let dir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let base = PathSafety.uniqueName(base: "\(stem).\(ext)", in: dir.path)
        return dir.appendingPathComponent(base)
    }
}
