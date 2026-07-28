import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GoelCore

/// An in-flight or finished SFTP transfer tracked by the app-wide transfer center, independent of
/// any browser view. One row per top-level item; a folder aggregates its whole subtree.
struct SFTPTransfer: Identifiable {
    enum Direction {
        case upload, download
        /// A remote→remote copy or move. SFTP has no server-side copy, so the bytes still stream
        /// through this machine — but never through a local file, hence no ``localURL``.
        case remoteCopy
    }
    enum State: Equatable { case running, finished, failed(String), cancelled }

    let id = UUID()
    /// The server this transfer belongs to, so the browser can filter to its own.
    let connectionID: UUID
    /// Not `let`: a download retry may land on a uniqued name, because the path this row first
    /// claimed can belong to another transfer by then.
    var name: String
    let direction: Direction
    /// True when an upload's source is a directory (uploaded recursively).
    let isDirectory: Bool
    /// The local file/folder: an upload's source or a download's destination. Nil for a
    /// ``Direction/remoteCopy``, which never touches disk. Mutable for the same reason as ``name``.
    var localURL: URL?
    /// The resolved remote target (upload) or remote source (download). Enough,
    /// with `connectionID`, to retry the transfer after a failure/cancel.
    let remotePath: String

    /// The containing remote directory shown by transfer surfaces and used for
    /// reveal-in-browser navigation.
    var remoteFolder: String { SFTPBrowserPaths.parent(of: remotePath) }

    /// A friendly folder label for compact transfer rows.
    var remoteFolderLabel: String { remoteFolder == "." ? "Home" : remoteFolder }
    var bytes: Int64 = 0
    var total: Int64 = 0
    /// Live throughput in bytes/sec — a sliding-window average (``SpeedMeter``, the same smoothing
    /// behind the download queue) so the readout is steady rather than per-chunk jitter.
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
         localURL: URL?, remotePath: String, total: Int64 = 0) {
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

    /// The rate to *display*: the smoothed window average, falling back to the plain average since
    /// the first byte while that window fills, so short transfers still show a rate.
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

    /// Absorb a fresh absolute byte count. `bytes` tracks every callback so the bar stays smooth;
    /// ``speed`` is the meter's window average, so it stays stable however bursty the callbacks.
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

/// Presentation derived once and shared by the browser's transfer tray and the menu-bar popover,
/// which each previously kept a verbatim (drift-prone) copy of this mapping.
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
        let base: String
        switch direction {
        case .upload:     base = "arrow.up.circle"
        case .download:   base = "arrow.down.circle"
        case .remoteCopy: base = "arrow.left.arrow.right.circle"
        }
        return (filledWhenFinished && state == .finished) ? base + ".fill" : base
    }

    /// The small arrow glyph beside a compact row.
    var arrowGlyph: String {
        switch direction {
        case .upload:     return "arrow.up"
        case .download:   return "arrow.down"
        case .remoteCopy: return "arrow.left.arrow.right"
        }
    }

    /// The colour that identifies the direction, independent of state.
    var directionTint: Color {
        switch direction {
        case .upload:     return Theme.teal
        case .download:   return Theme.green
        case .remoteCopy: return Theme.accent
        }
    }

    /// What this row is doing, as a present-participle headline.
    var activityLabel: String {
        switch direction {
        case .upload:     return "Uploading"
        case .download:   return "Downloading"
        case .remoteCopy: return "Copying"
        }
    }

    /// The noun used when asking whether to cancel this row.
    var cancelNoun: String {
        switch direction {
        case .upload:     return "upload"
        case .download:   return "download"
        case .remoteCopy: return "copy"
        }
    }

    /// The preposition naming ``remoteFolderLabel``'s role for this direction.
    var folderPreposition: String {
        direction == .download ? "From" : "To"
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

/// A thread-safe cancel flag shared between a drag's `Progress.cancellationHandler` (main thread)
/// and the blocking download's progress callback (a libssh2 thread).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Drives one SFTP server browser: current directory, listing, and interactive transfers.
/// Navigation is string-path based — libssh2 resolves relative paths against the login home.
@MainActor
final class SFTPBrowserModel: ObservableObject {

    @Published private(set) var connection: SFTPConnection
    private var client: SFTPClient?
    private let locationStore: SFTPBrowserLocationStore

    @Published private(set) var path: String
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    /// Visited-path history for browser-style back / forward navigation.
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    init(connection: SFTPConnection, client: SFTPClient?,
         locationStore: SFTPBrowserLocationStore = .shared) {
        self.connection = connection
        self.client = client
        self.locationStore = locationStore
        self.path = locationStore.path(for: connection.id)
            ?? (connection.initialPath.isEmpty ? "." : connection.initialPath)
        Self.sweepStaleDragTemps()
    }

    /// Re-point this browser at an edited connection. SwiftUI keeps this `@StateObject` alive across
    /// an edit, so the owning view must forward the fresh client or every operation uses stale credentials.
    func update(connection: SFTPConnection, client: SFTPClient?) {
        self.connection = connection
        self.client = client
    }

    /// Whether we're at the login home (can't go up meaningfully).
    var isAtRoot: Bool { path == "." || path == "/" || path.isEmpty }

    /// A friendly path label for the breadcrumb bar.
    var displayPath: String { path == "." ? "Home" : path }

    // MARK: Navigation

    /// Restore the last successfully browsed folder. A stale saved folder is
    /// discarded and retried from the connection's configured start folder.
    func restore() async {
        let savedPath = locationStore.path(for: connection.id)
        let fallback = connection.initialPath.isEmpty ? "." : connection.initialPath
        let candidate = savedPath ?? fallback

        if let listed = await list(candidate) {
            commit(path: candidate, entries: listed)
        } else if savedPath != nil {
            locationStore.removePath(for: connection.id)
            backStack.removeAll()
            forwardStack.removeAll()
            if candidate != fallback, let listed = await list(fallback) {
                commit(path: fallback, entries: listed)
            }
        }
    }

    /// Re-list the current directory without changing browser history.
    func refresh() async {
        guard !isLoading, let listed = await list(path) else { return }
        commit(path: path, entries: listed)
    }

    func open(_ entry: SFTPEntry) async {
        // The name is server-supplied and joined onto the browsed path, so a listing entry named ".."
        // or "a/b" would silently walk the user out of the tree they think they're in.
        guard entry.isDirectory, SFTPBrowserPaths.isSafeChildName(entry.name) else { return }
        await navigate(to: Self.join(path, entry.name))
    }

    func goUp() async {
        guard !isAtRoot else { return }
        await navigate(to: Self.parent(of: path))
    }

    /// Jump straight to a path — used by breadcrumbs and transfer-row reveals.
    /// Requests wait behind a listing already in flight instead of being dropped.
    @discardableResult
    func go(toPath newPath: String) async -> Bool {
        while isLoading {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard !Task.isCancelled else { return false }
        if newPath == path { return true }
        return await navigate(to: newPath)
    }

    /// List first, then commit the path and history. A failed target leaves the
    /// last valid folder, listing, and persisted location untouched.
    @discardableResult
    private func navigate(to newPath: String) async -> Bool {
        guard !isLoading, newPath != path, let listed = await list(newPath) else { return false }
        backStack.append(path)
        forwardStack.removeAll()
        commit(path: newPath, entries: listed)
        return true
    }

    /// Step back to the previously-visited path (browser-style).
    func goBack() async {
        guard !isLoading, let previous = backStack.last,
              let listed = await list(previous) else { return }
        backStack.removeLast()
        forwardStack.append(path)
        commit(path: previous, entries: listed)
    }

    /// Step forward again after going back.
    func goForward() async {
        guard !isLoading, let next = forwardStack.last,
              let listed = await list(next) else { return }
        forwardStack.removeLast()
        backStack.append(path)
        commit(path: next, entries: listed)
    }

    private func list(_ target: String) async -> [SFTPEntry]? {
        guard let client else { error = "This server is misconfigured."; return nil }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            return try await client.list(target).sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch let e as SFTPError {
            error = e.message
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func commit(path newPath: String, entries newEntries: [SFTPEntry]) {
        path = newPath
        entries = newEntries
        locationStore.setPath(newPath, for: connection.id)
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

    // MARK: Metadata

    /// Full attributes for one entry, for the info panel. Reads the *link* rather
    /// than its target, and separately resolves where a link points.
    func info(for entry: SFTPEntry) async -> SFTPEntryInfo? {
        guard let client, SFTPBrowserPaths.isSafeChildName(entry.name) else { return nil }
        let full = Self.join(path, entry.name)
        do {
            let attributes = try await client.attributes(full)
            // A link's target is a second round trip, so only pay it for links. An unreadable target is
            // not an error — a dangling link is perfectly ordinary in an info panel.
            var target: String?
            if attributes.isSymlink {
                target = try? await client.linkTarget(full)
            }
            return SFTPEntryInfo(name: entry.name, path: full,
                                 attributes: attributes, linkTarget: target)
        } catch let e as SFTPError {
            error = e.message; return nil
        } catch {
            self.error = error.localizedDescription; return nil
        }
    }

    /// Apply a new permission mode to an entry, then re-list so the change shows.
    @discardableResult
    func setPermissions(_ entry: SFTPEntry, mode: UInt32) async -> Bool {
        guard let client, SFTPBrowserPaths.isSafeChildName(entry.name) else { return false }
        do {
            try await client.setPermissions(Self.join(path, entry.name), mode)
            await refresh()
            return true
        } catch let e as SFTPError { error = e.message; return false } catch { self.error = error.localizedDescription; return false }
    }

    /// Free/total space on the volume holding the current folder, or nil when the server doesn't
    /// support the query. Runs on the background connection so a slow answer never delays a click.
    func volumeSpace() async -> SFTPVolumeSpace? {
        guard let client else { return nil }
        return try? await client.onBackground().freeSpace(path)
    }

    /// The total size of a folder's subtree — what the info panel shows in place
    /// of the meaningless directory-inode size the listing carries.
    func recursiveSize(of entry: SFTPEntry, shouldContinue: @escaping @Sendable () -> Bool) async -> Int64? {
        guard let client, entry.isDirectory, SFTPBrowserPaths.isSafeChildName(entry.name) else { return nil }
        return try? await SFTPRelay.treeSize(client.onBackground(),
                                             path: Self.join(path, entry.name),
                                             shouldContinue: shouldContinue)
    }

    // MARK: Transfers — owned by the app-wide center on ``AppViewModel`` so they outlive this browser.
    // Only the drag-out provider stays here, because Finder drives its lifecycle and cancellation.

    /// A drag-out provider for a remote file: Finder pulls bytes on demand, so nothing downloads
    /// until the drop is accepted. Captures only `client` and paths, never the main-actor model.
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
            // Cancelling the drag must actually stop the network transfer, not just the wrapping Task —
            // the blocking download runs on its own thread and only observes this flag on progress ticks.
            let cancelled = CancelFlag()
            // The listing's byte count is the server's claim, not a fact, and a drag-out has no size check
            // of its own — so bound what a gesture can pull into the temp directory.
            let cap = ByteCap(limit: Self.dragOutByteCap)
            let task = Task {
                do {
                    try await client.downloadToFile(
                        remote: remote, localURL: tmp,
                        shouldContinue: { !cancelled.isCancelled && cap.underLimit }
                    ) { sofar, total in cap.observe(sofar: sofar, total: total) }
                    guard cap.underLimit else {
                        try? FileManager.default.removeItem(at: tmpDir)
                        completion(nil, false, Self.tooLargeToDrag(safeName))
                        return
                    }
                    completion(tmp, false, nil)
                    // The system copies our file after the handler returns; give
                    // it a wide margin, then remove the temp copy.
                    Self.scheduleTempCleanup(tmpDir)
                } catch {
                    // Tripping the cap aborts the transfer, so the throw arrives
                    // as a bare "Aborted" — say what actually happened.
                    try? FileManager.default.removeItem(at: tmpDir)
                    let failure: Error = cap.underLimit ? error : Self.tooLargeToDrag(safeName)
                    completion(nil, false, failure)
                }
            }
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = { cancelled.cancel(); task.cancel() }
            return progress
        }
        return provider
    }

    /// The most a single drag-out pulls to disk before being abandoned; matches the preview cap.
    /// `nonisolated` because the drag-out closure that reads it is @Sendable and a constant needs no actor.
    private nonisolated static let dragOutByteCap: Int64 = 512 * 1024 * 1024

    private nonisolated static func tooLargeToDrag(_ name: String) -> SFTPError {
        SFTPError(kind: .io, message: "“\(name)” is too large to drag out of the browser.")
    }

    // MARK: Path helpers (delegate to the tested GoelCore logic)

    static func join(_ base: String, _ child: String) -> String {
        SFTPBrowserPaths.join(base, child)
    }

    static func parent(of path: String) -> String {
        SFTPBrowserPaths.parent(of: path)
    }

    // MARK: Local-path safety + drag-out temp housekeeping

    /// Whether `url` resolves inside `directory`, via ``PathSafety/isContained(_:within:)`` — which
    /// resolves symlinks, unlike a purely textual check. `nonisolated`: pure path arithmetic.
    nonisolated static func isContained(_ url: URL, in directory: URL) -> Bool {
        PathSafety.isContained(url.path, within: directory.path)
    }

    /// Remove a drag-out temp directory after the system has had time to copy the file out.
    /// `nonisolated` so the background file-provider handler can call it off the main actor.
    private nonisolated static func scheduleTempCleanup(_ dir: URL) {
        Task.detached {
            try? await Task.sleep(nanoseconds: 120 * NSEC_PER_SEC)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Backstop for the delayed cleanup above (e.g. if the app quit first): remove `GoelSFTP-*` temp
    /// directories older than an hour, so an in-flight sibling drag is never disturbed.
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
