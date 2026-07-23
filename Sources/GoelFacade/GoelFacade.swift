import Foundation
import GoelContracts
import GoelCore

/// A synchronous / callback-based facade over the async ``DownloadManager``.
///
/// The engine is a graph of Swift actors reached only through `await`, and
/// `async` does not cross the JNI (or any C-ABI) boundary. This facade is the seam
/// that makes a non-Swift consumer possible:
///
/// - every operation is a **blocking** call (see ``runBlocking(_:)``) that returns
///   JSON, and
/// - live updates arrive by **callback registration** (``observe(_:)``) instead of
///   an `AsyncStream`, which also cannot cross JNI.
///
/// Payloads are `GoelContracts` value types as UTF-8 JSON, encoded with
/// ``makeEncoder()`` — note it pins `.secondsSince1970`, because Foundation's
/// *default* date strategy is seconds since **2001-01-01**, which a Kotlin twin
/// reading Unix epoch would misread by 31 years. Always encode/decode this
/// boundary with ``makeEncoder()``/``makeDecoder()``.
///
/// **Threading:** call from a *foreign* thread (the JVM thread, an app main
/// thread), never from inside a Swift `Task` — see ``runBlocking(_:)``. Callbacks
/// from ``observe(_:)`` are delivered on a private serial queue, off the
/// cooperative pool, precisely so a callback *may* safely re-enter these blocking
/// methods.
public final class GoelFacade: @unchecked Sendable {

    /// A live subscription: the stream-consuming task plus the private queue its
    /// callbacks are delivered on.
    private struct Subscription {
        let task: Task<Void, Never>
        let queue: DispatchQueue
    }

    private let manager: DownloadManager

    private let lock = NSLock()
    private var subscriptions: [Int: Subscription] = [:]
    // Handle 0 is never issued, so a C caller can use it as a null sentinel.
    private var nextHandle = 1

    /// Settings fields the facade neither reveals nor lets a caller write:
    /// `remoteToken` is a live bearer token granting full remote control of the
    /// engine, and `remotePasswordHash` is offline-brute-forceable credential
    /// material. Both would otherwise cross into a foreign runtime's heap (and
    /// from there into logs or a crash reporter) on every ``settingsJSON()``.
    /// They are stripped on read and preserved-from-current on write, so a
    /// read-modify-write cycle can neither leak nor erase them.
    private static let secretSettingsKeys = ["remoteToken", "remotePasswordHash"]

    // MARK: Init

    /// Wrap an existing manager. The composition root supplies engines, ports and
    /// the store — inject a real torrent factory here on a build that ships
    /// `GoelTorrent`; an iOS build simply omits it.
    public init(manager: DownloadManager) {
        self.manager = manager
    }

    deinit {
        // A dropped facade must not leave subscriptions (and the manager they
        // capture) running forever: a bare `Task` is NOT cancelled when its
        // handle is released. Best-effort only — `deinit` must never block.
        for subscription in subscriptions.values { subscription.task.cancel() }
    }

    /// The JSON encoder/decoder pair defining this boundary's wire format.
    /// Sorted keys for determinism; `.secondsSince1970` so dates are unambiguous
    /// across languages.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// The contract / wire-DTO schema version this engine speaks.
    public var schemaVersion: Int { GoelContract.schemaVersion }

    /// Test-only access to the wrapped manager. Secrets are redacted from the
    /// public JSON surface by design, so a test cannot otherwise assert that a
    /// read-modify-write round-trip preserved them.
    internal var managerForTesting: DownloadManager { manager }

    // MARK: Lifecycle

    /// Restore the queue + settings from the on-disk store. Call once after init,
    /// before adding work.
    ///
    /// Returns the persistence warning the engine raises when the store could not
    /// be read (a corrupt or unreadable database), or `nil` on a clean restore —
    /// otherwise a foreign caller cannot tell "fresh install" from "your saved
    /// queue is gone".
    @discardableResult
    public func restore() -> String? {
        runBlocking { [manager] in
            await manager.restore()
            return await manager.currentPersistenceWarning
        }
    }

    /// The current persistence warning, if any (see ``restore()``).
    public func persistenceWarning() -> String? {
        runBlocking { [manager] in await manager.currentPersistenceWarning }
    }

    /// Cancel every live subscription (quiescently), then shut the manager down.
    public func shutdown() {
        for handle in currentHandles() { cancel(handle) }
        runBlocking { [manager] in await manager.shutdown() }
    }

    // MARK: Observe (blocking snapshot)

    /// Point-in-time task list as a JSON array of ``DownloadTask``.
    ///
    /// Throws rather than returning an empty array if encoding fails — an empty
    /// list and a serialization failure must never look alike to a caller.
    public func snapshotJSON() throws -> Data {
        let tasks = runBlocking { [manager] in await manager.taskSnapshot() }
        return try Self.makeEncoder().encode(Self.sanitized(tasks))
    }

    /// Current ``AppSettings`` as JSON, with secret fields stripped
    /// (see ``secretSettingsKeys``).
    public func settingsJSON() throws -> Data {
        let settings = runBlocking { [manager] in await manager.currentSettings }
        var object = try Self.jsonObject(of: settings)
        for key in Self.secretSettingsKeys { object.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: Observe (callback registration — the AsyncStream replacement)

    /// Register a callback that fires with a JSON snapshot (`[DownloadTask]`)
    /// whenever the queue changes — the callback replacement for the manager's
    /// `AsyncStream`, which cannot cross JNI.
    ///
    /// Fires once immediately with the current snapshot, then on every change,
    /// until ``cancel(_:)`` or ``shutdown()``. Returns a handle (never 0).
    ///
    /// Callbacks are delivered serially on a private `DispatchQueue`, *not* on
    /// Swift's cooperative pool, so a callback may safely call back into the
    /// blocking methods here. The subscription uses `.bufferingNewest(1)`: each
    /// element is a whole snapshot, so a slow consumer should skip stale frames
    /// rather than accumulate them.
    ///
    /// Do not call ``cancel(_:)`` for this handle from inside its own callback —
    /// cancellation waits for the callback queue to drain.
    public func observe(_ callback: @Sendable @escaping (Data) -> Void) -> Int {
        let queue = DispatchQueue(label: "com.goel.facade.observer")
        let task = Task { [manager] in
            let stream = await manager.updates(bufferingPolicy: .bufferingNewest(1))
            for await snapshot in stream {
                // Sanitized so encoding cannot fail here (a callback has no way
                // to report an error); `snapshotJSON()` stays strict + throwing.
                guard let data = try? Self.makeEncoder().encode(Self.sanitized(snapshot)) else { continue }
                // Hop off the cooperative pool *before* running foreign code:
                // a callback that re-entered `runBlocking` on a pool thread would
                // park that thread and starve the runtime.
                queue.async { callback(data) }
            }
        }
        lock.lock(); defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        subscriptions[handle] = Subscription(task: task, queue: queue)
        return handle
    }

    /// Cancel a subscription created by ``observe(_:)``. Unknown handles no-op.
    ///
    /// **Quiescent:** when this returns, the stream loop has exited *and* any
    /// already-queued callback has finished, so a JNI caller can safely release
    /// the callback's global reference immediately afterwards.
    public func cancel(_ handle: Int) {
        lock.lock()
        let subscription = subscriptions.removeValue(forKey: handle)
        lock.unlock()
        guard let subscription else { return }
        subscription.task.cancel()
        runBlocking { _ = await subscription.task.value }   // loop has exited
        subscription.queue.sync {}                          // pending callbacks drained
    }

    private func currentHandles() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return Array(subscriptions.keys)
    }

    // MARK: Mutate

    /// Add a download from a raw URL / magnet line (the same scheme allowlist the
    /// rest of the app uses). Returns the created — or deduplicated — task as JSON.
    ///
    /// - Throws: ``FacadeError/invalidSource(_:)`` if the line fails the allowlist,
    ///   or ``FacadeError/disallowedSaveDirectory(_:)`` if `saveDirectory` escapes
    ///   the configured downloads root.
    public func add(_ line: String, saveDirectory: String? = nil, startPaused: Bool = false) throws -> Data {
        guard let source = DownloadSource.parse(line) else { throw FacadeError.invalidSource(line) }
        let directory = try containedSaveDirectory(saveDirectory)
        let task = runBlocking { [manager] in
            await manager.add(source: source, saveDirectory: directory, startPaused: startPaused)
        }
        return try Self.makeEncoder().encode(task)
    }

    @discardableResult public func pause(_ id: String) -> TaskOpResult {
        perform(id) { [manager] in await manager.pause($0) }
    }

    @discardableResult public func resume(_ id: String) -> TaskOpResult {
        perform(id) { [manager] in await manager.resume($0) }
    }

    @discardableResult public func retry(_ id: String) -> TaskOpResult {
        perform(id) { [manager] in await manager.retry($0) }
    }

    @discardableResult public func remove(_ id: String, deleteData: Bool) -> TaskOpResult {
        perform(id) { [manager] in await manager.remove($0, deleteData: deleteData) }
    }

    public func pauseAll() { runBlocking { [manager] in await manager.pauseAll() } }
    public func resumeAll() { runBlocking { [manager] in await manager.resumeAll() } }

    // MARK: Settings

    /// Apply a **partial** settings patch: the caller's keys are overlaid onto the
    /// current settings.
    ///
    /// This is deliberately a merge, not a replace. `AppSettings.init(from:)`
    /// defaults every absent key, so decoding a partial payload and storing it
    /// wholesale would silently reset ~95 unrelated fields — wiping the user's
    /// profiles, schedule and remote credentials on the most natural call a
    /// settings screen makes (`{"defaultSaveDirectory": "…"}`).
    ///
    /// Secret fields are preserved from the current settings and cannot be set
    /// through this path (see ``secretSettingsKeys``).
    ///
    /// - Throws: ``FacadeError/malformedSettings(_:)`` if the payload isn't a JSON
    ///   object or doesn't merge into valid settings. Silence here would leave a
    ///   caller believing its change had been applied.
    public func updateSettings(_ json: Data) throws {
        let patch: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                throw FacadeError.malformedSettings("payload is not a JSON object")
            }
            patch = object
        } catch let error as FacadeError {
            throw error
        } catch {
            throw FacadeError.malformedSettings("payload is not valid JSON: \(error)")
        }

        let current = runBlocking { [manager] in await manager.currentSettings }
        var merged = try Self.jsonObject(of: current)
        for (key, value) in patch where !Self.secretSettingsKeys.contains(key) {
            merged[key] = value
        }

        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        let settings: AppSettings
        do {
            settings = try Self.makeDecoder().decode(AppSettings.self, from: mergedData)
        } catch {
            throw FacadeError.malformedSettings("patch does not merge into valid settings: \(error)")
        }
        runBlocking { [manager] in await manager.updateSettings(settings) }
    }

    // MARK: Helpers

    /// Constrain a caller-supplied save directory to the configured downloads
    /// root, mirroring the guard the remote portal applies to the same input
    /// (`RemoteRouter.remoteSaveDirectory`): without it a caller could drop a file
    /// into an auto-run location such as `~/Library/LaunchAgents` or `/etc/cron.d`.
    /// The facade is by design driven by another runtime, so the directory string
    /// may well originate outside Swift (an Android share-intent, a WebView).
    ///
    /// Empty/whitespace resolves to `nil` (the engine's safe per-source default)
    /// rather than a relative path; an out-of-root path is refused loudly rather
    /// than silently downgraded.
    private func containedSaveDirectory(_ requested: String?) throws -> String? {
        guard let directory = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else { return nil }
        let root = runBlocking { [manager] in await manager.currentSettings }.defaultSaveDirectory
        guard PathSafety.isContained(directory, within: root) else {
            throw FacadeError.disallowedSaveDirectory(directory)
        }
        return directory
    }

    /// Run a per-task op, distinguishing a malformed id and an unknown task from
    /// success — the manager itself silently no-ops on both, which is fine for an
    /// in-process Swift caller that can re-observe, but leaves a foreign caller
    /// with no signal at all.
    private func perform(_ id: String, _ op: @Sendable @escaping (UUID) async -> Void) -> TaskOpResult {
        guard let uuid = UUID(uuidString: id) else { return .invalidID }
        return runBlocking { [manager] in
            guard await manager.task(uuid) != nil else { return TaskOpResult.notFound }
            await op(uuid)
            return TaskOpResult.ok
        }
    }

    /// Encode a value and re-read it as a JSON object, for key-level editing.
    private static func jsonObject<T: Encodable>(of value: T) throws -> [String: Any] {
        let data = try makeEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FacadeError.encodingFailed(String(describing: T.self))
        }
        return object
    }

    /// Replace non-finite `Double`s with finite stand-ins. `JSONEncoder` *throws*
    /// on NaN/±infinity, and a speed is a computed rate that can go non-finite on
    /// a zero-length interval — without this, one bad reading fails the whole
    /// snapshot. Clamping keeps the pinned numeric wire contract intact (rather
    /// than emitting `"inf"` strings a Kotlin decoder wouldn't expect).
    private static func sanitized(_ tasks: [DownloadTask]) -> [DownloadTask] {
        tasks.map { task in
            var copy = task
            if !copy.downloadSpeed.isFinite { copy.downloadSpeed = 0 }
            if !copy.uploadSpeed.isFinite { copy.uploadSpeed = 0 }
            if let ratio = copy.seedRatioLimit, !ratio.isFinite { copy.seedRatioLimit = nil }
            if let pieces = copy.pieceAvailability {
                copy.pieceAvailability = pieces.map { $0.isFinite ? $0 : 0 }
            }
            return copy
        }
    }
}

/// The outcome of a per-task operation, so a caller can tell a bad id from an
/// unknown task from a real change.
public enum TaskOpResult: String, Sendable, Equatable {
    case ok
    /// The id string was not a UUID.
    case invalidID
    /// No task with that id is in the queue.
    case notFound
}

/// Errors surfaced synchronously across the facade boundary.
public enum FacadeError: Error, Equatable {
    /// The add line failed the scheme allowlist (`DownloadSource.parse`).
    case invalidSource(String)
    /// The requested save directory escapes the configured downloads root.
    case disallowedSaveDirectory(String)
    /// The settings payload was not valid JSON, or did not merge into valid settings.
    case malformedSettings(String)
    /// A contract type failed to encode — always a bug, never caller input.
    case encodingFailed(String)
}
