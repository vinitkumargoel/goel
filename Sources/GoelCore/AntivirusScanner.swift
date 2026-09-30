import Foundation

enum AntivirusScanner {
    /// 300s ceiling: a wedged scanner would otherwise leak the process and park the continuation forever.
    private static let timeout: Duration = .seconds(300)

    static func scan(
        path: String,
        executablePath: String,
        argumentTemplate: String
    ) async -> ScanResult {
        let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Security: a concrete absolute executable only — never a $PATH name, never a shell interpreter.
        guard ProcessSafety.isSafeExecutable(executable) else {
            return .error(L10n.t("the scanner set in Settings can’t be run"))
        }

        let arguments = argumentTemplate
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "%path%", with: path) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Don't hand the third-party scanner our full environment.
        process.environment = ProcessSafety.minimalEnvironment

        return await withCheckedContinuation { (continuation: CheckedContinuation<ScanResult, Never>) in
            let gate = ScanGate(process: process, continuation: continuation)
            process.terminationHandler = { gate.complete(Self.verdict(for: $0)) }
            do {
                try process.run()
                gate.arm(Task.detached {
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    gate.timeoutKill()
                })
            } catch {
                // The termination handler never fires on a launch failure, so resume here.
                process.terminationHandler = nil
                gate.complete(.error(L10n.t("the scanner couldn’t be started: %@", error.localizedDescription)))
            }
        }
    }

    /// A non-zero exit is the scanner's "found something"; dying on a signal is it failing, not a verdict.
    static func verdict(for process: Process) -> ScanResult {
        if process.terminationReason == .uncaughtSignal {
            return .error(L10n.t("the scanner stopped unexpectedly"))
        }
        return process.terminationStatus == 0 ? .clean : .infected
    }
}

/// Resumes the continuation exactly once and owns the non-`Sendable` `Process` behind a lock.
private final class ScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timer: Task<Void, Never>?
    private let process: Process
    private let continuation: CheckedContinuation<ScanResult, Never>

    init(process: Process, continuation: CheckedContinuation<ScanResult, Never>) {
        self.process = process
        self.continuation = continuation
    }

    /// Every scan otherwise leaves a 300 s sleeper behind.
    func arm(_ timeout: Task<Void, Never>) {
        lock.lock()
        let done = finished
        if !done { timer = timeout }
        lock.unlock()
        if done { timeout.cancel() }   // the scanner already exited
    }

    func complete(_ result: ScanResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = timer
        timer = nil
        lock.unlock()
        pending?.cancel()
        continuation.resume(returning: result)
    }

    func timeoutKill() {
        lock.lock()
        let alreadyDone = finished
        lock.unlock()
        guard !alreadyDone else { return }
        // Verdict first: the SIGTERM below fires the termination handler, which must not report "stopped unexpectedly".
        complete(.error(L10n.t("the scanner took longer than 5 minutes and was stopped")))
        if process.isRunning { process.terminate() }
    }
}
