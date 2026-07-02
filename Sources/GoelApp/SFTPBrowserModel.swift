import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GoelCore

/// An in-flight interactive transfer shown in the browser's activity strip.
struct SFTPTransfer: Identifiable {
    enum Direction { case upload, download }
    let id = UUID()
    let name: String
    let direction: Direction
    var bytes: Int64 = 0
    var total: Int64 = 0
    var finished = false
    var error: String?

    var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
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

    let connection: SFTPConnection
    private let client: SFTPClient?

    @Published var path: String
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published private(set) var transfers: [SFTPTransfer] = []

    init(connection: SFTPConnection, client: SFTPClient?) {
        self.connection = connection
        self.client = client
        self.path = connection.initialPath.isEmpty ? "." : connection.initialPath
        Self.sweepStaleDragTemps()
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
        path = Self.join(path, entry.name)
        await refresh()
    }

    func goUp() async {
        guard !isAtRoot else { return }
        path = Self.parent(of: path)
        await refresh()
    }

    func navigate(to newPath: String) async {
        path = newPath.isEmpty ? "." : newPath
        await refresh()
    }

    // MARK: Mutations

    func makeDirectory(named name: String) async {
        guard let client, !name.isEmpty else { return }
        do {
            try await client.mkdir(Self.join(path, name))
            await refresh()
        } catch let e as SFTPError { error = e.message } catch { self.error = error.localizedDescription }
    }

    func delete(_ entry: SFTPEntry) async {
        guard let client else { return }
        do {
            try await client.remove(Self.join(path, entry.name), isDirectory: entry.isDirectory)
            await refresh()
        } catch let e as SFTPError { error = e.message } catch { self.error = error.localizedDescription }
    }

    // MARK: Transfers

    /// Upload local files (from a Finder drop) into the current directory.
    func upload(localURLs: [URL]) {
        guard let client else { return }
        for url in localURLs {
            let name = url.lastPathComponent
            let remote = Self.join(path, name)
            let transferID = beginTransfer(name: name, direction: .upload)
            Task { [weak self] in
                do {
                    try await client.upload(localURL: url, remote: remote) { [weak self] sofar, total in
                        Task { @MainActor in self?.updateTransfer(transferID, bytes: sofar, total: total) }
                    }
                    self?.finishTransfer(transferID, error: nil)
                    await self?.refresh()
                } catch let e as SFTPError {
                    self?.finishTransfer(transferID, error: e.message)
                } catch {
                    self?.finishTransfer(transferID, error: error.localizedDescription)
                }
            }
        }
    }

    /// Download a remote entry to a local directory (context-menu "Download to…").
    func download(_ entry: SFTPEntry, to localDirectory: URL) {
        guard let client, !entry.isDirectory else { return }
        let remote = Self.join(path, entry.name)
        // The entry name is server-supplied; never let it steer the *local*
        // path. Sanitize to a single safe component (defeats `../` traversal /
        // absolute paths) before joining it onto the user's chosen folder.
        let safeName = DownloadTask.sanitizedName(entry.name)
        let destination = localDirectory.appendingPathComponent(safeName)
        guard Self.isContained(destination, in: localDirectory) else {
            error = "Refusing to write \"\(entry.name)\" outside the chosen folder."
            return
        }
        let transferID = beginTransfer(name: safeName, direction: .download)
        Task { [weak self] in
            do {
                try await client.downloadToFile(remote: remote, localURL: destination) { [weak self] sofar, total in
                    Task { @MainActor in self?.updateTransfer(transferID, bytes: sofar, total: total) }
                }
                self?.finishTransfer(transferID, error: nil)
            } catch let e as SFTPError {
                self?.finishTransfer(transferID, error: e.message)
            } catch {
                self?.finishTransfer(transferID, error: error.localizedDescription)
            }
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.finished }
    }

    /// A drag-out provider for a remote file: Finder pulls the bytes on demand
    /// via `registerFileRepresentation`, so nothing downloads until the drop is
    /// accepted. Only the `client` and computed paths are captured (never the
    /// main-actor model), so the background load handler stays Sendable-safe.
    func fileProvider(for entry: SFTPEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        // Sanitize the server-supplied name: it names the *local* dropped file
        // and the temp path we write, so a traversal name must not escape.
        let safeName = DownloadTask.sanitizedName(entry.name)
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

    // MARK: Transfer bookkeeping

    private func beginTransfer(name: String, direction: SFTPTransfer.Direction) -> UUID {
        let t = SFTPTransfer(name: name, direction: direction)
        transfers.append(t)
        return t.id
    }

    private func updateTransfer(_ id: UUID, bytes: Int64, total: Int64) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].bytes = bytes
        transfers[idx].total = total
    }

    private func finishTransfer(_ id: UUID, error: String?) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].finished = true
        transfers[idx].error = error
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
