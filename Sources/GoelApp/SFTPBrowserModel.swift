import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GoelCore

struct SFTPTransfer: Identifiable {
    enum Direction {
        case upload, download
        case remoteCopy
    }
    /// `.waiting` is a transfer admitted to the list but with no bytes moved yet —
    /// usually queued behind the per-server connection cap. `.paused` keeps its
    /// partial file on disk so a resume can pick up from the byte it stopped at.
    enum State: Equatable { case waiting, running, paused, finished, failed(String), cancelled }

    let id = UUID()
    let connectionID: UUID
    var name: String
    let direction: Direction
    let isDirectory: Bool
    var localURL: URL?
    let remotePath: String

    var remoteFolder: String { SFTPBrowserPaths.parent(of: remotePath) }

    var remoteFolderLabel: String { remoteFolder == "." ? "Home" : remoteFolder }
    var bytes: Int64 = 0
    var total: Int64 = 0
    var speed: Double = 0
    /// Born waiting: the first recorded byte flips it to `.running`, so a row queued
    /// behind the per-server connection cap says so instead of faking activity.
    var state: State = .waiting

    /// Direction-agnostic: an upload's bytes also ride the meter's `down` channel.
    private var meter = SpeedMeter()

    private var firstByteAt: Date?
    private var lastByteAt: Date?

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
    var isActive: Bool { state == .running || state == .waiting }
    var isPaused: Bool { state == .paused }
    /// Rows that still own their destination file/name: in flight, or paused with a partial on disk.
    var occupiesDestination: Bool { isActive || isPaused }
    /// Pause is offered only where a byte offset can be resumed; a remote copy restarts instead.
    var canPause: Bool { state == .running && direction != .remoteCopy }
    var canResume: Bool { state == .paused }

    /// Written by the app-wide 500 ms sampler, exactly like a download task's
    /// displayed speed: rows stop flickering at the raw progress rate, and a
    /// stalled transfer decays to zero instead of freezing at its last reading.
    var sampledSpeed: Double?

    var displaySpeed: Double { sampledSpeed ?? liveSpeed(at: Date()) }

    /// The meter's sliding window re-read at `now` — so it decays during a stall —
    /// and hard-zeroed after 5 s of silence, because the window average alone only
    /// shrinks asymptotically and would show a trickle forever. The cumulative
    /// fallback covers the window's first half-second dead zone.
    func liveSpeed(at now: Date) -> Double {
        guard isActive else { return 0 }
        if let lastByteAt, now.timeIntervalSince(lastByteAt) > 5 { return 0 }
        let windowed = meter.reading(at: now).down
        if windowed > 0 { return windowed }
        guard bytes > 0, let firstByteAt else { return 0 }
        let elapsed = now.timeIntervalSince(firstByteAt)
        guard elapsed >= 0.2 else { return 0 }
        return Double(bytes) / elapsed
    }

    var etaSeconds: TimeInterval? {
        let rate = displaySpeed
        guard isActive, rate > 0, total > bytes else { return nil }
        return Double(total - bytes) / rate
    }

    mutating func record(bytes newBytes: Int64, now: Date = Date()) {
        if firstByteAt == nil, newBytes > 0 { firstByteAt = now }
        if newBytes > 0 { lastByteAt = now }
        // The first byte is the proof the transfer got a connection and left the queue.
        if state == .waiting, newBytes > 0 { state = .running }
        bytes = newBytes
        meter.record(down: newBytes, at: now)
        speed = meter.reading(at: now).down
    }

    mutating func resetProgress() {
        bytes = 0
        speed = 0
        sampledSpeed = nil
        meter = SpeedMeter()
        firstByteAt = nil
        lastByteAt = nil
    }
}

extension SFTPTransfer {
    var tint: Color {
        switch state {
        case .failed: return Theme.red
        case .finished: return Theme.green
        case .cancelled: return .secondary
        case .running: return Theme.accent
        case .waiting: return .secondary
        case .paused: return Theme.orange
        }
    }

    func iconName(filledWhenFinished: Bool) -> String {
        let base: String
        switch direction {
        case .upload:     base = "arrow.up.circle"
        case .download:   base = "arrow.down.circle"
        case .remoteCopy: base = "arrow.left.arrow.right.circle"
        }
        return (filledWhenFinished && state == .finished) ? base + ".fill" : base
    }

    var arrowGlyph: String {
        switch direction {
        case .upload:     return "arrow.up"
        case .download:   return "arrow.down"
        case .remoteCopy: return "arrow.left.arrow.right"
        }
    }

    var directionTint: Color {
        switch direction {
        case .upload:     return Theme.teal
        case .download:   return Theme.green
        case .remoteCopy: return Theme.accent
        }
    }

    var activityLabel: String {
        switch direction {
        case .upload:     return "Uploading"
        case .download:   return "Downloading"
        case .remoteCopy: return "Copying"
        }
    }

    var cancelNoun: String {
        switch direction {
        case .upload:     return "upload"
        case .download:   return "download"
        case .remoteCopy: return "copy"
        }
    }

    var folderPreposition: String {
        direction == .download ? "From" : "To"
    }

    var progressLabel: String {
        total > 0 ? "\(Int(fraction * 100))%" : bytes.byteString
    }

    var sizeLabel: String {
        total > 0 ? "\(bytes.byteString) / \(total.byteString)" : bytes.byteString
    }

    var speedLabel: String { displaySpeed > 0 ? displaySpeed.speedString : "" }

    var etaLabel: String? { etaSeconds.map { DownloadTask.etaString($0) } }
}

/// Crosses threads: the main-thread drag cancellation handler vs. the libssh2 progress callback.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class SFTPBrowserModel: ObservableObject {

    @Published private(set) var connection: SFTPConnection
    private var client: SFTPClient?
    private let locationStore: SFTPBrowserLocationStore

    @Published private(set) var path: String
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    /// Non-nil while a (possibly recursive) delete runs; rendered as a busy banner.
    @Published private(set) var deleteProgress: String?
    private var deleteCancel: CancelFlag?

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

    /// SwiftUI keeps this `@StateObject` across an edit — the owner must forward the fresh client or operations use stale credentials.
    func update(connection: SFTPConnection, client: SFTPClient?) {
        self.connection = connection
        self.client = client
    }

    var isAtRoot: Bool { path == "." || path == "/" || path.isEmpty }

    var displayPath: String { path == "." ? "Home" : path }

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

    func refresh() async {
        guard !isLoading, let listed = await list(path) else { return }
        commit(path: path, entries: listed)
    }

    func open(_ entry: SFTPEntry) async {
        // Server-supplied name joined onto the browsed path: ".." or "a/b" would walk out of the tree.
        guard entry.isDirectory, SFTPBrowserPaths.isSafeChildName(entry.name) else { return }
        await navigate(to: Self.join(path, entry.name))
    }

    func goUp() async {
        guard !isAtRoot else { return }
        await navigate(to: Self.parent(of: path))
    }

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

    @discardableResult
    private func navigate(to newPath: String) async -> Bool {
        guard !isLoading, newPath != path, let listed = await list(newPath) else { return false }
        backStack.append(path)
        forwardStack.removeAll()
        commit(path: newPath, entries: listed)
        return true
    }

    func goBack() async {
        guard !isLoading, let previous = backStack.last,
              let listed = await list(previous) else { return }
        backStack.removeLast()
        forwardStack.append(path)
        commit(path: previous, entries: listed)
    }

    func goForward() async {
        guard !isLoading, let next = forwardStack.last,
              let listed = await list(next) else { return }
        forwardStack.removeLast()
        backStack.append(path)
        commit(path: next, entries: listed)
    }

    private func list(_ target: String) async -> [SFTPEntry]? {
        guard let client else { error = L10n.t("This server is misconfigured."); return nil }
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
        let result = await deleteMany([entry])
        return result.deleted == 1 && result.failure == nil
    }

    /// Deletes every item (folders recursively), refreshes ONCE at the end, and
    /// re-asserts the first failure AFTER that refresh — `list()` clears `error`,
    /// so setting it earlier left a failed delete showing nothing at all.
    func deleteMany(_ items: [SFTPEntry]) async -> (deleted: Int, failure: String?) {
        guard client != nil else { return (0, error) }
        let flag = CancelFlag()
        deleteCancel = flag
        var deleted = 0
        var failure: String?
        for (index, entry) in items.enumerated() {
            if flag.isCancelled { failure = failure ?? L10n.t("Delete cancelled."); break }
            deleteProgress = items.count > 1
                ? L10n.t("Deleting “%1$@” (%2$d of %3$d)…", entry.name, index + 1, items.count)
                : L10n.t("Deleting “%@”…", entry.name)
            if await deleteOne(entry, flag: flag) { deleted += 1 }
            else { failure = failure ?? error }
        }
        deleteProgress = nil
        deleteCancel = nil
        await refresh()
        if let failure { error = failure }
        return (deleted, failure)
    }

    func cancelDelete() { deleteCancel?.cancel() }

    private func deleteOne(_ entry: SFTPEntry, flag: CancelFlag) async -> Bool {
        guard let client else { return false }
        // Server-supplied name joined onto the browsed path: ".." or "a/b" would walk out of the tree.
        guard SFTPBrowserPaths.isSafeChildName(entry.name) else {
            error = L10n.t("“%@” has a name Goel can’t handle safely.", entry.name)
            return false
        }
        let full = Self.join(path, entry.name)
        do {
            if entry.isDirectory && !entry.isSymlink {
                // rmdir refuses non-empty directories: the tree is emptied bottom-up first.
                let name = entry.name
                try await SFTPRelay.removeTree(client.onBackground(), path: full,
                                               shouldContinue: { !flag.isCancelled },
                                               onProgress: { [weak self] done, planned in
                    // Every unlink is one round trip; a per-item hop to the main actor is not.
                    guard done.isMultiple(of: 20) || done == planned else { return }
                    Task { @MainActor in
                        guard let self, self.deleteProgress != nil else { return }
                        self.deleteProgress = L10n.t("Deleting “%1$@” — %2$d of %3$d items…",
                                                     name, done, planned)
                    }
                })
            } else {
                // Files, and symlinks even when they point at directories, are unlinked.
                try await client.remove(full, isDirectory: false)
            }
            return true
        } catch let e as SFTPError { error = e.message; return false } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func rename(_ entry: SFTPEntry, to newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty, trimmed != entry.name,
              !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return false }
        if entries.contains(where: { $0.name == trimmed }) {
            error = L10n.t("“%@” already exists here.", trimmed); return false
        }
        do {
            try await client.rename(Self.join(path, entry.name), to: Self.join(path, trimmed))
            await refresh()
            return true
        } catch let e as SFTPError { error = e.message; return false } catch { self.error = error.localizedDescription; return false }
    }

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

    func info(for entry: SFTPEntry) async -> SFTPEntryInfo? {
        guard let client, SFTPBrowserPaths.isSafeChildName(entry.name) else { return nil }
        let full = Self.join(path, entry.name)
        do {
            let attributes = try await client.attributes(full)
            // A dangling link is ordinary here, so an unreadable target must not be an error.
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

    @discardableResult
    func setPermissions(_ entry: SFTPEntry, mode: UInt32) async -> Bool {
        guard let client, SFTPBrowserPaths.isSafeChildName(entry.name) else { return false }
        do {
            try await client.setPermissions(Self.join(path, entry.name), mode)
            await refresh()
            return true
        } catch let e as SFTPError { error = e.message; return false } catch { self.error = error.localizedDescription; return false }
    }

    func volumeSpace() async -> SFTPVolumeSpace? {
        guard let client else { return nil }
        return try? await client.onBackground().freeSpace(path)
    }

    func recursiveSize(of entry: SFTPEntry,
                       shouldContinue: @escaping @Sendable () -> Bool) async -> Result<Int64, SFTPError>? {
        guard let client, entry.isDirectory, SFTPBrowserPaths.isSafeChildName(entry.name) else { return nil }
        do {
            return .success(try await SFTPRelay.treeSize(client.onBackground(),
                                                         path: Self.join(path, entry.name),
                                                         shouldContinue: shouldContinue))
        } catch let e as SFTPError {
            return .failure(e)
        } catch {
            return .failure(SFTPError(kind: .io, message: error.localizedDescription))
        }
    }

    /// The provider closure must capture only `client` and paths, never the main-actor model.
    func fileProvider(for entry: SFTPEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        // Server-supplied name: it names the local dropped file and temp path, so traversal must not escape.
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
            // Cancelling the Task alone will not stop the blocking download; it only observes this flag.
            let cancelled = CancelFlag()
            // The server's claimed byte count is not a fact: bound what one gesture can pull to disk.
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
                    // The system copies the file only after this handler returns — do not delete it now.
                    Self.scheduleTempCleanup(tmpDir)
                } catch {
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

    private nonisolated static let dragOutByteCap: Int64 = 512 * 1024 * 1024

    private nonisolated static func tooLargeToDrag(_ name: String) -> SFTPError {
        SFTPError(kind: .io, message: L10n.t("“%@” is too large to drag out of the browser.", name))
    }

    static func join(_ base: String, _ child: String) -> String {
        SFTPBrowserPaths.join(base, child)
    }

    static func parent(of path: String) -> String {
        SFTPBrowserPaths.parent(of: path)
    }

    /// Resolves symlinks, unlike a purely textual containment check.
    nonisolated static func isContained(_ url: URL, in directory: URL) -> Bool {
        PathSafety.isContained(url.path, within: directory.path)
    }

    private nonisolated static func scheduleTempCleanup(_ dir: URL) {
        Task.detached {
            try? await Task.sleep(nanoseconds: 120 * NSEC_PER_SEC)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// The one-hour cutoff is what keeps this sweep from deleting an in-flight sibling drag.
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
