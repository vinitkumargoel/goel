import Foundation

/// Post-download malware screening hook.
///
/// When the user enables antivirus scanning in Settings, the scheduler hands a
/// freshly completed file to `scan(path:executablePath:argumentTemplate:)`,
/// which shells out to the configured scanner (ClamAV's `clamscan`, or any
/// other command-line tool) and reports whether the file passed.
///
/// The scanner is treated as a black box: a **zero** exit status means the scan
/// succeeded with a clean result, while any non-zero status — or a failure to
/// launch the process at all — is reported as a failure so the caller can act
/// on it rather than silently trusting an unscanned file.
enum AntivirusScanner {

    /// Run `executablePath` against `path`, expanding `%path%` in the argument
    /// template, and report whether the scan passed (process exited `0`).
    ///
    /// The template is split on whitespace into individual arguments and every
    /// `%path%` token is replaced with the file path, so a template like
    /// `--quiet %path%` against `/tmp/x.dmg` becomes `["--quiet", "/tmp/x.dmg"]`.
    /// An empty executable path short-circuits to `false` (there is nothing to
    /// run); a process that throws on launch or exits non-zero is also `false`.
    /// The app is unsandboxed and the scanner path/template come from the settings
    /// DB, which any same-user process can write, so the executable is vetted by
    /// ``ProcessSafety/isSafeExecutable(_:)`` (absolute, executable, not a shell
    /// interpreter) before launch — closing the `/bin/sh -c <payload>` bridge.

    /// Hard ceiling on how long a scanner may run before it is killed and the
    /// scan reported as failed — prevents a wedged scanner from leaking the
    /// process and parking the continuation forever.
    private static let timeout: Duration = .seconds(300)

    static func scan(
        path: String,
        executablePath: String,
        argumentTemplate: String
    ) async -> Bool {
        let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        // The scanner must be a concrete, absolute, executable file — never a
        // relative name resolved through $PATH and never a shell interpreter.
        guard ProcessSafety.isSafeExecutable(executable) else { return false }

        // Split the template on whitespace and expand each `%path%` token.
        let arguments = argumentTemplate
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "%path%", with: path) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Don't hand the third-party scanner our full environment.
        process.environment = ProcessSafety.minimalEnvironment

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ScanGate(process: process, continuation: continuation)
            process.terminationHandler = { gate.complete($0.terminationStatus == 0) }
            do {
                try process.run()
                // Watchdog: kill the scanner and fail the scan if it never exits.
                Task.detached { try? await Task.sleep(for: timeout); gate.timeoutKill() }
            } catch {
                // Failed to even launch the scanner; the termination handler never
                // fires, so report the failure here.
                process.terminationHandler = nil
                gate.complete(false)
            }
        }
    }
}

/// Resumes a scan's continuation exactly once — whichever of {process exit,
/// launch failure, watchdog timeout} happens first — and owns the non-`Sendable`
/// `Process` behind a lock so the watchdog can terminate it safely.
private final class ScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let process: Process
    private let continuation: CheckedContinuation<Bool, Never>

    init(process: Process, continuation: CheckedContinuation<Bool, Never>) {
        self.process = process
        self.continuation = continuation
    }

    func complete(_ passed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: passed)
    }

    func timeoutKill() {
        lock.lock()
        let alreadyDone = finished
        lock.unlock()
        guard !alreadyDone else { return }
        if process.isRunning { process.terminate() }   // no-op if it already exited
        complete(false)
    }
}
