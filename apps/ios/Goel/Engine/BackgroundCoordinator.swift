import Foundation
import OSLog
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

// MARK: - BackgroundEvent

/// What the out-of-process downloader reports back to the engine.
///
/// Deliberately tiny and absolute: `contiguousBytes` is *how far byte 0 now reaches*, never a
/// delta. A delta can be applied twice — and the whole point of `sessionSendsLaunchEvents` is
/// that a completion can be delivered to a **freshly launched process** that has no idea what it
/// already counted.
public enum BackgroundEvent: Sendable {
    case progress(id: UUID, contiguousBytes: Int64)
    case finished(id: UUID, contiguousBytes: Int64)
    case failed(id: UUID, error: TransferError)
}

// MARK: - BackgroundEventsRegistry

/// Holds the completion handler iOS hands us in
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
///
/// Calling it is not optional. iOS wakes the app, replays the background session's delegate
/// callbacks, and then waits for this handler before it will let the app settle — if it is never
/// called the app is terminated, and anything it was about to persist is lost. `@MainActor`
/// because that is where UIKit hands it over and where it insists on being called back.
@MainActor
public enum BackgroundEventsRegistry {
    private static var handlers: [String: () -> Void] = [:]

    public static func store(identifier: String, handler: @escaping () -> Void) {
        handlers[identifier] = handler
    }

    public static func fire(identifier: String) {
        guard let handler = handlers.removeValue(forKey: identifier) else { return }
        handler()
    }
}

// MARK: - GoelAppDelegate

#if canImport(UIKit)
/// The one job this delegate has.
///
/// `GoelApp.swift` is owned by another task, so it is not edited here. To wire this up, add a
/// single stored property to `struct GoelApp` — see the note in `BackgroundCoordinator`'s
/// documentation.
public final class GoelAppDelegate: NSObject, UIApplicationDelegate {

    public func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundCoordinator.handleEvents(identifier: identifier, completionHandler: completionHandler)
    }
}
#endif

// MARK: - BackgroundCoordinator

/// The out-of-process half of PRD §4.1's Handoff model.
///
/// The foreground engine is fast because it runs six sockets we control. iOS will not let us keep
/// those sockets when the app suspends, and the only thing it *will* keep running is a background
/// `URLSession`, which is system-managed, out-of-process, and will not run our segmentation. The
/// two are architecturally incompatible, so the app switches between them: segmented in the
/// foreground, one background task for `[contiguous prefix, total]` when suspended.
///
/// ## Wiring (three lines the app must add)
///
/// `GoelApp.swift` needs these, and nothing else:
///
/// ```swift
/// // inside `struct GoelApp: App`
/// @UIApplicationDelegateAdaptor(GoelAppDelegate.self) private var appDelegate
/// ```
///
/// ## Rules that are not negotiable
///
/// - **Exactly one** session with `GoelIdentifiers.backgroundSessionID` for the process lifetime.
///   Constructing a second with the same identifier traps at runtime, so the session is created
///   once inside a mutex and never rebuilt.
/// - **One task per download.** Not six. A background session is system-scheduled; six tasks
///   would be six independent things the system can defer, and there is no way to make them write
///   into one sparse file out of process. Single-stream-but-it-finishes is the deliberate trade.
/// - **Never cancel on the first error.** The background session does its own retrying across
///   network changes and airplane-mode toggles; duplicating that logic here would fight it.
public final class BackgroundCoordinator: NSObject, URLSessionDownloadDelegate, Sendable {

    public static let shared = BackgroundCoordinator()

    private let state = Mutex<State>(State())
    private let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "background")

    private struct State {
        var session: URLSession?
        var store = FileStore()
        var observer: (@Sendable (BackgroundEvent) -> Void)?
    }

    // MARK: - Configuration

    /// The engine hands over its `FileStore` so a test-injected container is honoured here too.
    public func configure(store: FileStore) {
        state.withLock { $0.store = store }
    }

    public func setObserver(_ observer: @escaping @Sendable (BackgroundEvent) -> Void) {
        state.withLock { $0.observer = observer }
    }

    /// Forces the background session into existence so iOS can replay its delegate callbacks
    /// after relaunching the app. Called from `handleEvents`.
    public func warmUp() {
        _ = backgroundSession()
    }

    @MainActor
    public static func handleEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == GoelIdentifiers.backgroundSessionID else {
            // Not ours. Release iOS immediately rather than holding the app open.
            completionHandler()
            return
        }
        BackgroundEventsRegistry.store(identifier: identifier, handler: completionHandler)
        BackgroundCoordinator.shared.warmUp()
        // The app may have been relaunched straight into the background, so `scenePhase` never
        // becomes `.active` and the two drain sites in `AppModel` never fire. Without this, a
        // Pause tapped in the Dynamic Island shows as paused while the transfer keeps running.
        onBackgroundWake?()
    }

    /// Set by `AppModel` at construction. Runs on every background-session wake.
    @MainActor public static var onBackgroundWake: (@MainActor () -> Void)?

    private func backgroundSession() -> URLSession {
        state.withLock { state in
            if let existing = state.session { return existing }
            let configuration = URLSessionConfiguration.background(
                withIdentifier: GoelIdentifiers.backgroundSessionID
            )
            // The user asked for this file. `true` lets iOS defer it indefinitely for power, which
            // is exactly the "it never finished" complaint the product exists to fix.
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
            configuration.allowsCellularAccess = true
            configuration.waitsForConnectivity = true
            // A week: a 4 GB file on a bad link, backgrounded overnight, must not time out.
            configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.name = "dev.goel.ios.background-session"
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            state.session = session
            return session
        }
    }

    private func currentStore() -> FileStore {
        state.withLock { $0.store }
    }

    private func emit(_ event: BackgroundEvent) {
        let observer = state.withLock { $0.observer }
        observer?(event)
    }

    // MARK: - Handoff in

    /// Starts the single background task for `range`, and records on disk everything needed to
    /// splice its result — because the process that receives that result may not be this one.
    public func beginBackgroundTransfer(
        downloadID: UUID,
        url: URL,
        range: ClosedRange<Int64>,
        validator: String?,
        totalBytes: Int64?,
        part: URL,
        destination: URL,
        checkpoint: URL
    ) {
        let store = currentStore()
        store.saveManifest(
            BackgroundHandoffManifest(
                downloadID: downloadID,
                url: url.absoluteString,
                partPath: part.path,
                destinationPath: destination.path,
                offset: range.lowerBound,
                totalBytes: totalBytes,
                validator: validator
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(HandoffState.rangeHeaderValue(range), forHTTPHeaderField: "Range")
        if let validator {
            // Without this, a file that changed on the server is spliced into bytes from the old
            // one and the result is a plausible-looking corrupt file.
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        let task = backgroundSession().downloadTask(with: request)
        // Survives app relaunch, unlike anything held in memory. This is how the delegate knows
        // which download a replayed completion belongs to.
        task.taskDescription = downloadID.uuidString
        task.priority = URLSessionTask.highPriority
        task.resume()
        log.info("background task started for \(downloadID, privacy: .public) at byte \(range.lowerBound)")
    }

    /// Stops the background task for a download. Used when the app returns to the foreground (the
    /// segmented engine takes over) and when the user pauses or cancels.
    public func cancelBackgroundTransfer(_ downloadID: UUID) {
        let key = downloadID.uuidString
        let store = currentStore()
        backgroundSession().getAllTasks { tasks in
            for task in tasks where task.taskDescription == key {
                task.cancel()
            }
            // Remove the manifest on the delegate queue, after any already-queued
            // `didFinishDownloadingTo` for this id has run (the queue is serial,
            // `maxConcurrentOperationCount == 1`). Removing it synchronously on the caller's
            // thread raced an in-flight completion, which then found no manifest and silently
            // dropped a finished background transfer.
            store.removeManifest(for: downloadID)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let raw = downloadTask.taskDescription, let id = UUID(uuidString: raw) else { return }
        guard let manifest = currentStore().loadManifest(for: id) else { return }
        // The task buffers to its own temp file, so these bytes are not in *our* file yet. They
        // are reported so the UI can move, never persisted as progress.
        emit(.progress(id: id, contiguousBytes: manifest.offset + max(0, totalBytesWritten)))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let raw = downloadTask.taskDescription, let id = UUID(uuidString: raw) else { return }
        let store = currentStore()
        guard let manifest = store.loadManifest(for: id) else {
            log.error("background completion with no manifest for \(raw, privacy: .public)")
            return
        }

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0

        // A 200 in answer to a ranged request means `If-Range` did not match: this body is the
        // whole of a *different* file. Splicing it at `offset` would be the exact corruption T06
        // exists to prevent.
        if manifest.offset > 0 && status != 206 {
            store.removeManifest(for: id)
            log.error("background transfer for \(id, privacy: .public) answered \(status) to a ranged request")
            emit(.failed(id: id, error: .remoteFileChanged))
            return
        }
        guard status == 206 || status == 200 else {
            store.removeManifest(for: id)
            emit(.failed(id: id, error: .network("The background transfer answered HTTP \(status).")))
            return
        }

        let checkpointURL = URL(filePath: manifest.destinationPath)
            .appendingPathExtension(FileStore.checkpointExtension)
        let existing = store.loadCheckpoint(at: checkpointURL)

        do {
            let written = try Self.splice(
                from: location,
                into: URL(filePath: manifest.partPath),
                at: manifest.offset,
                store: store,
                totalBytes: manifest.totalBytes
            )
            var ranges = existing?.completedRanges ?? []
            if written > 0 {
                ranges.append(manifest.offset...(manifest.offset + written - 1))
            }
            let merged = HandoffState.merged(ranges)
            store.saveCheckpoint(
                TransferCheckpoint(
                    url: manifest.url,
                    totalBytes: manifest.totalBytes,
                    validator: manifest.validator,
                    supportsResume: existing?.supportsResume ?? true,
                    isSequential: existing?.isSequential ?? false,
                    completed: merged
                ),
                at: checkpointURL
            )
            store.removeManifest(for: id)
            log.info("background transfer for \(id, privacy: .public) spliced \(written) bytes at \(manifest.offset)")
            emit(.finished(id: id, contiguousBytes: HandoffState.contiguousPrefix(of: merged)))
        } catch {
            // The bytes are still in the part file up to whatever was written; the checkpoint is
            // untouched, so nothing is lost beyond this attempt.
            store.removeManifest(for: id)
            log.error("background splice failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            emit(.failed(id: id, error: .network(error.localizedDescription)))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }  // success is handled in didFinishDownloadingTo
        guard let raw = task.taskDescription, let id = UUID(uuidString: raw) else { return }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            // Us taking the transfer back for the foreground engine. Not a failure.
            return
        }
        currentStore().removeManifest(for: id)
        log.error("background transfer for \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        emit(.failed(id: id, error: .network(error.localizedDescription)))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? GoelIdentifiers.backgroundSessionID
        Task { @MainActor in
            BackgroundEventsRegistry.fire(identifier: identifier)
        }
    }

    // MARK: - Splice

    /// Copies the background task's temp file into the real `.part` at `offset`, streamed.
    ///
    /// Must finish before this returns: iOS deletes `source` the moment the delegate method exits.
    /// Streamed in 1 MB chunks because `source` can be gigabytes and this runs on a phone.
    static func splice(
        from source: URL,
        into part: URL,
        at offset: Int64,
        store: FileStore,
        totalBytes: Int64?
    ) throws -> Int64 {
        let file = try store.openPart(at: part, size: totalBytes)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }

        var written: Int64 = 0
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            try file.write(chunk, at: offset + written)
            written += Int64(chunk.count)
        }
        file.synchronize()
        return written
    }
}
