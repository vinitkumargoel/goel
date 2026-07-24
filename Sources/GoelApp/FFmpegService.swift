import Foundation
import GoelCore

/// Hand-off to `ffmpeg` for post-download media work: remuxing/converting a
/// finished video and extracting its audio track.
///
/// A packaged build carries its OWN static ffmpeg inside `Contents/Resources`
/// (see `Scripts/fetch_ffmpeg.sh`), because "no Homebrew required" is the whole
/// promise of a self-contained .app — and for a long time it was not true here:
/// the build script shipped no copy and this type auto-detected `/opt/homebrew`,
/// so Convert and Extract Audio simply did not exist for anyone who had never
/// installed Homebrew. That is the failure this file is written to make loud.
///
/// Resolution order is: the user's explicit Settings override, then the bundled
/// copy, then the common system install locations. The override wins over the
/// bundled binary on purpose — a user who typed a path did so to use THAT build
/// (a newer one, or a GPL build with encoders the bundled LGPL one lacks).
enum FFmpegService {

    /// Where the ffmpeg we are about to run came from. Carried in errors and the
    /// diagnostics text so "it works on my Mac" is an answerable question.
    enum Source: String, Sendable {
        case override, bundled, system
    }

    /// The outcome of looking for ffmpeg: a usable binary and its provenance, or
    /// a sentence that can be shown to a person as-is.
    enum Availability: Sendable {
        case found(URL, Source)
        case missing(String)
    }

    /// Candidate system install locations, in the order they are tried. `$PATH`
    /// is deliberately NOT consulted: the app runs with whatever environment
    /// Finder handed it, which is not the user's shell `PATH`, so searching it
    /// would be theatre — and honouring an inherited `PATH` would let any
    /// same-user process decide which binary a "Convert" click launches.
    private static let systemCandidates = [
        "/opt/homebrew/bin/ffmpeg",     // Homebrew, Apple silicon
        "/usr/local/bin/ffmpeg",        // Homebrew, Intel (and hand-installs)
        "/opt/local/bin/ffmpeg",        // MacPorts
        NSHomeDirectory() + "/.local/bin/ffmpeg",
    ]

    /// The bundled binary's path, whether or not it exists.
    private static var bundledPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("ffmpeg", isDirectory: false).path
    }

    /// Full resolution, including the reason when it fails.
    static func resolve(override: String = "") -> Availability {
        let fm = FileManager.default
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        // The override path comes from the settings DB (same-user-writable). Only
        // accept it if it's a concrete absolute non-interpreter executable — never
        // a relative $PATH name or a shell/script interpreter, which would turn a
        // "Convert"/"Extract Audio" click into arbitrary code execution. Mirrors
        // the guard AntivirusScanner already applies to its equivalent setting.
        if !trimmed.isEmpty {
            if ProcessSafety.isSafeExecutable(trimmed) {
                return .found(URL(fileURLWithPath: trimmed), .override)
            }
            // A bad override is the one case we must NOT quietly fall through on:
            // the user typed a path, believes it is in effect, and would otherwise
            // never learn why nothing changed.
            return .missing(overrideRejectionMessage(for: trimmed))
        }

        if let bundledPath {
            if fm.isExecutableFile(atPath: bundledPath) {
                return .found(URL(fileURLWithPath: bundledPath), .bundled)
            }
            // Present but not runnable: the copy survived into the bundle and then
            // lost its execute bit (unzipped by a tool that drops permissions) or
            // was stripped by an over-eager cleaner. Distinct message — "install
            // ffmpeg" is the wrong advice here.
            if fm.fileExists(atPath: bundledPath) {
                return .missing("""
                    Goel°’s built-in media converter is present but macOS won’t run it. \
                    This usually means the app was unpacked by a tool that dropped file \
                    permissions — drag Goel° to Applications from the original download, \
                    or re-download it.
                    """)
            }
        }

        if let system = systemCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return .found(URL(fileURLWithPath: system), .system)
        }
        return .missing("""
            Goel° couldn’t find ffmpeg, the tool it uses to convert video and pull out \
            audio. This copy of the app was built without the included one, and there \
            isn’t an ffmpeg installed on this Mac. Re-download Goel° from the official \
            release page to get the built-in copy, or install ffmpeg yourself and enter \
            its full path in Settings → Media tools → “ffmpeg path”.
            """)
    }

    /// Locate the ffmpeg binary, or nil when nothing usable was found. Thin
    /// wrapper over ``resolve(override:)`` for call sites that only need the path.
    static func executable(override: String = "") -> URL? {
        if case .found(let url, _) = resolve(override: override) { return url }
        return nil
    }

    static func isAvailable(override: String = "") -> Bool {
        if case .found = resolve(override: override) { return true }
        return false
    }

    /// The plain-language reason ffmpeg can't be used, or nil when it can.
    ///
    /// The UI should show this instead of hiding Convert / Extract Audio: a menu
    /// item that silently isn't there teaches the user the app can't do the job,
    /// which is both wrong and unfixable from their side.
    static func unavailableReason(override: String = "") -> String? {
        if case .missing(let reason) = resolve(override: override) { return reason }
        return nil
    }

    /// Why a configured override was refused, in the user's terms.
    private static func overrideRejectionMessage(for path: String) -> String {
        let fm = FileManager.default
        if !path.hasPrefix("/") {
            return "The ffmpeg path in Settings (“\(path)”) isn’t a full path. "
                 + "Enter the complete location, e.g. /opt/homebrew/bin/ffmpeg, or clear "
                 + "the field to use the copy included with Goel°."
        }
        if !fm.fileExists(atPath: path) {
            return "There’s no file at the ffmpeg path set in Settings (“\(path)”). "
                 + "Fix the path, or clear the field to use the copy included with Goel°."
        }
        if ProcessSafety.interpreterBlocklist.contains(path) {
            return "The ffmpeg path in Settings points at “\(path)”, which is a script "
                 + "interpreter rather than ffmpeg. Goel° won’t run it. Clear the field to "
                 + "use the copy included with Goel°."
        }
        return "The ffmpeg path in Settings (“\(path)”) isn’t a program Goel° can run. "
             + "Clear the field to use the copy included with Goel°."
    }

    /// One line describing where ffmpeg resolved from, for the Settings pane and
    /// the diagnostics bundle. Never contains user content beyond the path they
    /// themselves typed.
    static func resolutionSummary(override: String = "") -> String {
        switch resolve(override: override) {
        case .found(let url, .override): return "Using the ffmpeg you set in Settings: \(url.path)"
        case .found(let url, .bundled):  return "Using the ffmpeg included with Goel° (\(url.lastPathComponent))"
        case .found(let url, .system):   return "Using the ffmpeg installed on this Mac: \(url.path)"
        case .missing(let reason):       return reason
        }
    }

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
        // Surface the SAME explanation the UI uses for the disabled state, rather
        // than a terse "not found — brew install" that is wrong for a user who
        // has no Homebrew and shouldn't need one.
        let exe: URL
        switch resolve(override: override) {
        case .found(let url, _): exe = url
        case .missing(let reason): return .failure(reason)
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
