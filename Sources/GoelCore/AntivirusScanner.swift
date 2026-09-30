import Foundation

enum AntivirusScanner {
    /// 300s ceiling: a wedged scanner would otherwise leak the process and park the continuation forever.
    private static let timeout: Duration = .seconds(300)

    static func scan(
        path: String,
        executablePath: String,
        argumentTemplate: String
    ) async -> Bool {
        let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Security: a concrete absolute executable only — never a $PATH name, never a shell interpreter.
        guard ProcessSafety.isSafeExecutable(executable) else { return false }

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
                gate.arm(Task.detached {
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    gate.timeoutKill()
                })
            } catch {
                // The termination handler never fires on a launch failure, so resume here.
                process.terminationHandler = nil
                gate.complete(false)
            }
        }
    }
}

/// Resumes the continuation exactly once and owns the non-`Sendable` `Process` behind a lock.
private final class ScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timer: Task<Void, Never>?
    private let process: Process
    private let continuation: CheckedContinuation<Bool, Never>

    init(process: Process, continuation: CheckedContinuation<Bool, Never>) {
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

    func complete(_ passed: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = timer
        timer = nil
        lock.unlock()
        pending?.cancel()
        continuation.resume(returning: passed)
    }

    func timeoutKill() {
        lock.lock()
        let alreadyDone = finished
        lock.unlock()
        guard !alreadyDone else { return }
        if process.isRunning { process.terminate() }
        complete(false)
    }
}
