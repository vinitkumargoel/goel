import Foundation

/// Post-download malware screening: the scheduler hands a finished file to the configured scanner
/// (ClamAV `clamscan` or similar). Exit `0` = clean; any non-zero, or a launch failure, = failed.
enum AntivirusScanner {

    /// Run `executablePath` on `path` (template split on whitespace, `%path%` expanded); passes on exit `0`.
    /// Settings-DB-supplied, so ``ProcessSafety/isSafeExecutable(_:)`` vets it — no `/bin/sh -c <payload>`.

    /// Hard ceiling before a scanner is killed and the scan reported failed — stops a wedged
    /// scanner from leaking the process and parking the continuation forever.
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

/// Resumes a scan's continuation exactly once (process exit, launch failure, or watchdog timeout)
/// and owns the non-`Sendable` `Process` behind a lock so the watchdog can terminate it safely.
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
