import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GoelCore

/// An in-flight (or finished) SFTP transfer tracked by the app-wide transfer
/// center (``AppViewModel`` + `AppViewModel+SFTPTransfers`). Lives independently
/// of any browser view, so it survives closing/switching the server browser and
/// stays cancellable; the browser and status bar just render it. One row per
/// top-level item picked/dropped — a folder aggregates its whole subtree.
struct SFTPTransfer: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case running, finished, failed(String), cancelled }

    let id = UUID()
    /// The server this transfer belongs to, so the browser can filter to its own.
    let connectionID: UUID
    let name: String
    let direction: Direction
    /// True when an upload's source is a directory (uploaded recursively).
    let isDirectory: Bool
    /// The local file/folder: an upload's source, or a download's destination.
    let localURL: URL
    /// The resolved remote target (upload) or remote source (download). Enough,
    /// with `connectionID`, to retry the transfer after a failure/cancel.
    let remotePath: String
    var bytes: Int64 = 0
    var total: Int64 = 0
    /// Live throughput in bytes/sec — a sliding-window average (see
    /// ``SpeedMeter``, the same smoothing behind the download queue's rates) so
    /// the readout is steady rather than per-chunk jitter.
    var speed: Double = 0
    var state: State = .running

    /// The window-averaging state behind ``speed``. Direction-agnostic: this
    /// transfer's byte counter rides the meter's `down` channel either way.
    private var meter = SpeedMeter()

    /// When the first byte was recorded — the origin for the warm-up average in
    /// ``displaySpeed``. Nil until the transfer actually starts moving data.
    private var firstByteAt: Date?

    /// Explicit init: the private sampling fields would otherwise make the
    /// synthesized memberwise initializer private.
    init(connectionID: UUID, name: String, direction: Direction, isDirectory: Bool,
         localURL: URL, remotePath: String, total: Int64 = 0) {
        self.connectionID = connectionID
        self.name = name
        self.direction = direction
        self.isDirectory = isDirectory
        self.localURL = localURL
        self.remotePath = remotePath
        self.total = total
    }

    var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
    var isActive: Bool { state == .running }
    var errorMessage: String? { if case .failed(let m) = state { return m }; return nil }

    /// The rate to *display*. Prefers the smoothed window average (``speed``), but
    /// while that window is still filling — under ``SpeedMeter/minimumSpan`` of
    /// history, where a fast LAN upload or a small file can finish before it warms
    /// up — falls back to the plain average since the first byte. Same code path
    /// for uploads and downloads, so a rate appears promptly either direction
    /// rather than the smoothing swallowing short transfers whole.
    var displaySpeed: Double {
        if speed > 0 { return speed }
        guard isActive, bytes > 0, let firstByteAt else { return 0 }
        let elapsed = Date().timeIntervalSince(firstByteAt)
        guard elapsed >= 0.2 else { return 0 }   // too little history to be meaningful
        return Double(bytes) / elapsed
    }

    /// Seconds remaining at the current rate, or nil if unknown/stalled — used
    /// for the transfer row's ETA.
    var etaSeconds: TimeInterval? {
        let rate = displaySpeed
        guard isActive, rate > 0, total > bytes else { return nil }
        return Double(total - bytes) / rate
    }

    /// Absorb a fresh absolute byte count. `bytes` tracks every callback so the
    /// progress bar stays smooth; ``speed`` is the meter's window average, so
    /// it stays stable no matter how bursty the callbacks are.
    mutating func record(bytes newBytes: Int64, now: Date = Date()) {
        if firstByteAt == nil, newBytes > 0 { firstByteAt = now }
        bytes = newBytes
        meter.record(down: newBytes, at: now)
        speed = meter.reading(at: now).down
    }

    /// Zero the counters + speed meter for an in-place retry.
    mutating func resetProgress() {
        bytes = 0
        speed = 0
        meter = SpeedMeter()
        firstByteAt = nil
    }
}

// MARK: - Shared row presentation

/// Presentation derived once and shared by the browser's transfer tray and the
/// menu-bar status popover, which previously each kept a verbatim copy of this
/// state→colour mapping and the progress label (drift-prone across the two views).
/// The two rows keep their own *layouts* (full vs compact) but no longer duplicate
/// this logic.
extension SFTPTransfer {
    /// Row tint by state.
    var tint: Color {
        switch state {
        case .failed: return Theme.red
        case .finished: return Theme.green
        case .cancelled: return .secondary
        case .running: return Theme.accent
        }
    }

    /// The direction icon. `filledWhenFinished` fills it on completion (the browser
    /// tray does; the compact status row keeps the outline).
    func iconName(filledWhenFinished: Bool) -> String {
        let base = direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        return (filledWhenFinished && state == .finished) ? base + ".fill" : base
    }

    /// The compact running-progress label: percent when the total is known, bytes otherwise.
    var progressLabel: String {
        total > 0 ? "\(Int(fraction * 100))%" : bytes.byteString
    }

    /// "12.34 MB / 45.67 MB" — bytes done over the known total (or just the
    /// running byte count when the total isn't known yet).
    var sizeLabel: String {
        total > 0 ? "\(bytes.byteString) / \(total.byteString)" : bytes.byteString
    }

    /// The live rate, e.g. "14.2 MB/s"; empty only for the first fraction of a
    /// second, before even the warm-up average is meaningful.
    var speedLabel: String { displaySpeed > 0 ? displaySpeed.speedString : "" }

    /// "1.2m" / "45s" remaining, or nil when unknown.
    var etaLabel: String? { etaSeconds.map { DownloadTask.etaString($0) } }
}

/// A thread-safe cancel flag shared between a drag's `Progress.cancellationHandler`
/// (main thread) and the blocking download's progress callback (a libssh2
/// thread), so cancelling a drag actually aborts the transfer.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Drives one SFTP server browser: current directory, listing, and the
/// interactive upload/download transfers. Navigation is string-path based —
/// libssh2 resolves relative paths against the login home, so "." is home and
/// child/parent paths are joined/trimmed here.
@MainActor
final class SFTPBrowserModel: ObservableObject {

    @Published private(set) var connection: SFTPConnection
    private var client: SFTPClient?

    @Published var path: String
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    /// Visited-path history for browser-style back / forward navigation.
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    init(connection: SFTPConnection, client: SFTPClient?) {
        self.connection = connection
        self.client = client
        self.path = connection.initialPath.isEmpty ? "." : connection.initialPath
        Self.sweepStaleDragTemps()
    }

    /// Re-point this browser at an edited connection (host/username/port/password
    /// may have changed). SwiftUI keeps this `@StateObject` alive across an edit
    /// because the connection's `id` is stable, so the owning view must forward
    /// the fresh connection/client here — otherwise every operation keeps using
    /// the pre-edit credentials captured at `init`. Keeps the current directory.
    func update(connection: SFTPConnection, client: SFTPClient?) {
        self.connection = connection
        self.client = client
    }

    /// Whether we're at the login home (can't go up meaningfully).
    var isAtRoot: Bool { path == "." || path == "/" || path.isEmpty }

    /// A friendly path label for the breadcrumb bar.
    var displayPath: String { path == "." ? "Home" : path }

    // MARK: Navigation

    func refresh() async {
        guard let client else { error = "This server is misconfigured."; return }
        isLoading = true
        error = nil
        do {
            let listed = try await client.list(path)
            entries = listed.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch let e as SFTPError {
            error = e.message
            entries = []
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
        isLoading = false
    }

    func open(_ entry: SFTPEntry) async {
        guard entry.isDirectory else { return }
        await navigate(to: Self.join(path, entry.name))
    }

    func goUp() async {
        guard !isAtRoot else { return }
        await navigate(to: Self.parent(of: path))
    }

    /// Jump straight to a path — used by the breadcrumb bar.
    func go(toPath newPath: String) async {
        await navigate(to: newPath)
    }

    /// Push the current path onto the back history and list `newPath`. Ignores a
    /// navigation fired while a listing is still in flight (re-entrancy guard:
    /// `refresh()` sets `isLoading` synchronously before it suspends, so a
    /// re-entrant tap would otherwise join onto the already-mutated path and race
    /// a concurrent `refresh()`).
    private func navigate(to newPath: String) async {
        guard !isLoading, newPath != path else { return }
        backStack.append(path)
        forwardStack.removeAll()
        path = newPath
        await refresh()
    }

    /// Step back to the previously-visited path (browser-style).
    func goBack() async {
        guard !isLoading, let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        path = previous
        await refresh()
    }

    /// Step forward again after going back.
    func goForward() async {
        guard !isLoading, let next = forwardStack.popLast() else { return }
        backStack.append(path)
        path = next
        await refresh()
    }

    // MARK: Mutations

    @discardableResult
    func makeDirectory(named name: String) async -> Bool {
        guard let client, !name.isEmpty else { return false }
        do {
            try await client.mkdir(Self.join(path, name))
            await refresh()
            return true
        } catch let e as SFTPError { error = e.message; return false } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func delete(_ entry: SFTPEntry) async -> Bool {
        guard let client else { return false }
        do {
            try await client.remove(Self.join(path, entry.name), isDirectory: entry.isDirectory)
            await refresh()
            return true
        } catch let e as SFTPError { error = e.message; return false } catch { self.error = error.localizedDescription; return false }
    }

    /// Rename an entry in place. Rejects empty/separator/`..` names and refuses to
    /// clobber an existing sibling.
    @discardableResult
    func rename(_ entry: SFTPEntry, to newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty, trimmed != entry.name,
              !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return false }
        if entries.contains(where: { $0.name == trimmed }) {
            error = "“\(trimmed)” already exists here."; return false
        }
        do {
            try await client.rename(Self.join(path, entry.name), to: Self.join(path, trimmed))
            await refresh()
            return true
        } catch let e as SFTPError { error = e.message; return false } catch { self.error = error.localizedDescription; return false }
    }

    /// Move an entry into another directory on the same server (a sibling
    /// subfolder, or the parent). `destDir` is the target directory path.
    @discardableResult
    func move(_ entry: SFTPEntry, toDirectory destDir: String) async -> Bool {
        guard let client else { return false }
        let source = Self.join(path, entry.name)
        let dest = Self.join(destDir, entry.name)
        guard dest != source else { return false }
        do {
            try await client.rename(source, to: dest)
            await refresh()
            return true
        } catch let e as SFTPError { error = e.message; return false } catch { self.error = error.localizedDescription; return false }
    }

    // MARK: Transfers
    //
    // Uploads and "Download to…" downloads are owned by the app-wide transfer
    // center on ``AppViewModel`` (see `AppViewModel+SFTPTransfers`), so they keep
    // running — and stay visible/cancellable — after this browser is closed. The
    // view starts them through `vm` and reads them back filtered by connection.
    // Only the drag-out provider below stays here, because Finder drives its
    // lifecycle (and its own cancellation) directly.

    /// A drag-out provider for a remote file: Finder pulls the bytes on demand
    /// via `registerFileRepresentation`, so nothing downloads until the drop is
    /// accepted. Only the `client` and computed paths are captured (never the
    /// main-actor model), so the background load handler stays Sendable-safe.
    func fileProvider(for entry: SFTPEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        // Sanitize the server-supplied name: it names the *local* dropped file
        // and the temp path we write, so a traversal name must not escape.
        let safeName = PathSafety.sanitizedName(entry.name)
        provider.suggestedName = safeName
        guard let client, !entry.isDirectory else { return provider }
        let remote = Self.join(path, entry.name)
        let ext = (safeName as NSString).pathExtension
        let typeID = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        provider.registerFileRepresentation(forTypeIdentifier: typeID,
                                            fileOptions: [], visibility: .all) { completion in
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("GoelSFTP-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let tmp = tmpDir.appendingPathComponent(safeName)
            // Cancelling the drag must actually stop the network transfer, not
            // just the wrapping Task — the blocking download runs on its own
            // thread and only observes this flag on progress ticks.
            let cancelled = CancelFlag()
            let task = Task {
                do {
                    try await client.downloadToFile(remote: remote, localURL: tmp,
                                                    shouldContinue: { !cancelled.isCancelled }) { _, _ in }
                    completion(tmp, false, nil)
                    // The system copies our file after the handler returns; give
                    // it a wide margin, then remove the temp copy.
                    Self.scheduleTempCleanup(tmpDir)
                } catch {
                    try? FileManager.default.removeItem(at: tmpDir)
                    completion(nil, false, error)
                }
            }
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = { cancelled.cancel(); task.cancel() }
            return progress
        }
        return provider
    }

    // MARK: Path helpers (delegate to the tested GoelCore logic)

    static func join(_ base: String, _ child: String) -> String {
        SFTPBrowserPaths.join(base, child)
    }

    static func parent(of path: String) -> String {
        SFTPBrowserPaths.parent(of: path)
    }

    // MARK: Local-path safety + drag-out temp housekeeping

    /// Whether `url` resolves to a path inside `directory` (belt-and-suspenders
    /// on top of `sanitizedName`, which already strips slashes and `..`).
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Remove a drag-out temp directory after the system has had time to copy
    /// the dropped file out of it. `nonisolated` so the background file-provider
    /// handler can call it off the main actor.
    private nonisolated static func scheduleTempCleanup(_ dir: URL) {
        Task.detached {
            try? await Task.sleep(nanoseconds: 120 * NSEC_PER_SEC)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Backstop for the delayed cleanup above (e.g. if the app quit first):
    /// remove any `GoelSFTP-*` temp directories older than an hour, so an
    /// in-flight sibling drag is never disturbed.
    private static func sweepStaleDragTemps() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in items where url.lastPathComponent.hasPrefix("GoelSFTP-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
