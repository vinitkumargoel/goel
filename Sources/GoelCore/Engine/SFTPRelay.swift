import Foundation
import SSHBridge

/// Copies remote files/folders. SFTP has no server-side copy (libssh2 1.11 can't send `copy-data@openssh.com`), so bytes
/// relay through ``SFTPRelayPipe`` on two *different* connections — one libssh2 session is one thread, so sharing deadlocks.
public enum SFTPRelay {

    /// What to do when the destination path already exists.
    public enum Collision: Sendable {
        /// Pick a free "name (2)" style name — what Finder does for a copy into
        /// the folder the item is already in.
        case rename
        /// Write over it.
        case overwrite
        /// Fail without transferring anything.
        case fail
    }

    /// One item to copy, resolved to absolute remote paths on each side.
    public struct Item: Sendable {
        public let sourcePath: String
        public let destinationPath: String
        public let size: Int64
        public let isDirectory: Bool

        public init(sourcePath: String, destinationPath: String, size: Int64, isDirectory: Bool) {
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.size = size
            self.isDirectory = isDirectory
        }
    }

    /// Copy one remote file, streaming it through this machine. `progress` reports bytes accepted by the *destination*:
    /// with a pipe in between, source progress would race ahead then appear to stall while the buffer drained.
    public static func copyFile(from source: SFTPClient, path sourcePath: String,
                                to destination: SFTPClient, path destinationPath: String,
                                size: Int64,
                                maxBytesPerSecond: Int64 = 0,
                                shouldContinue: @escaping @Sendable () -> Bool = { true },
                                progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let pipe = SFTPRelayPipe()

        // An empty file still has to be created; short-circuit the relay. `size` came from a possibly-stale listing and
        // this path skips the shim's arrival check, so re-read it — an unreadable size falls through to streaming, which verifies.
        var bytes = size
        if bytes <= 0, let current = try? await source.size(sourcePath) { bytes = current }
        guard bytes > 0 else {
            try await destination.uploadStream(remote: destinationPath, total: 0,
                                               shouldContinue: shouldContinue,
                                               read: { _ in 0 },
                                               progress: progress)
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // The read half. `streamingDownload` reports through its result
                // rather than throwing, so translate here.
                let result = await source.streamingDownload(
                    remote: sourcePath, resumeFrom: 0, maxBytesPerSecond: maxBytesPerSecond,
                    write: { buf in pipe.write(buf) },
                    progress: { _, _ in shouldContinue() })
                if result.code == GSB_OK {
                    pipe.finish()
                } else {
                    // Tell the writer why, then let the failure surface as a throw
                    // so the group cancels the upload too.
                    pipe.fail(result.message)
                    throw result.asError(host: source.target.host, port: source.target.port,
                                         username: source.target.username)
                }
            }
            group.addTask {
                // The write half.
                do {
                    try await destination.uploadStream(
                        remote: destinationPath, total: bytes,
                        maxBytesPerSecond: maxBytesPerSecond,
                        shouldContinue: shouldContinue,
                        read: { buf in pipe.read(into: buf) },
                        progress: progress)
                } catch {
                    // Unblock the source, which may be parked on a full pipe.
                    pipe.fail(error.localizedDescription)
                    throw error
                }
            }
            // Surface the first failure and cancel the other half. Both tasks
            // unblock because whichever failed already called `fail`.
            do {
                try await group.waitForAll()
            } catch {
                pipe.fail(error.localizedDescription)
                group.cancelAll()
                throw error
            }
        }
    }

    /// Copy a whole remote directory tree. Directories are created shallowest-first so every file has a parent by
    /// the time it is written. `onFileProgress` receives (path, bytes copied for that file, that file's total).
    public static func copyTree(from source: SFTPClient, path sourceRoot: String,
                                to destination: SFTPClient, path destinationRoot: String,
                                maxBytesPerSecond: Int64 = 0,
                                shouldContinue: @escaping @Sendable () -> Bool = { true },
                                onFileStart: @escaping @Sendable (String, Int64) -> Void = { _, _ in },
                                onFileProgress: @escaping @Sendable (String, Int64) -> Void = { _, _ in }) async throws {
        let plan = try await walk(source, root: sourceRoot, shouldContinue: shouldContinue)
        try requireComplete(plan)

        try await makeDirectory(destinationRoot, on: destination)
        for relative in plan.directories {
            guard shouldContinue() else { throw SFTPError(kind: .aborted, message: "Cancelled") }
            try await makeDirectory(relative.reduce(destinationRoot, SFTPBrowserPaths.join),
                                    on: destination)
        }

        for file in plan.files {
            guard shouldContinue() else { throw SFTPError(kind: .aborted, message: "Cancelled") }
            let from = file.relative.reduce(sourceRoot, SFTPBrowserPaths.join)
            let to = file.relative.reduce(destinationRoot, SFTPBrowserPaths.join)
            onFileStart(from, file.size)
            try await copyFile(from: source, path: from, to: destination, path: to,
                               size: file.size, maxBytesPerSecond: maxBytesPerSecond,
                               shouldContinue: shouldContinue,
                               progress: { sofar, _ in onFileProgress(from, sofar) })
        }
    }

    /// The total byte count of a remote tree — what a copy's progress bar needs
    /// before the first byte moves.
    public static func treeSize(_ client: SFTPClient, path root: String,
                                shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws -> Int64 {
        try await walk(client, root: root, shouldContinue: shouldContinue)
            .files.reduce(0) { $0 + $1.size }
    }

    // MARK: Walking

    public struct FileEntry: Sendable {
        /// Path components from the walk root, so a plan can be replayed against
        /// either a remote or a local destination.
        public let relative: [String]
        public let size: Int64
    }

    public struct TreePlan: Sendable {
        public let directories: [[String]]   // shallowest first
        public let files: [FileEntry]
        /// Names the walk refused to include because they carried path structure. Surfaced rather than dropped:
        /// a copy that quietly omits part of the tree and reports success is the failure mode worth avoiding.
        public let skipped: [String]
    }

    /// Ceilings on a walk, because the tree is described entirely by an untrusted server: a crafted listing
    /// (100k levels deep, or millions of entries) can exhaust memory and CPU before a single byte is copied.
    public static let maxWalkEntries = 500_000
    public static let maxWalkDepth = 128

    /// `mkdir` where only "it already exists" may fail. The blanket `try?` this replaces also swallowed permission-denied,
    /// quota and name-collision. Existence is re-checked, not inferred: the shim reports every mkdir failure the same way.
    public static func makeDirectory(_ path: String, on client: SFTPClient) async throws {
        do {
            try await client.mkdir(path)
        } catch let error as SFTPError {
            guard let existing = try? await client.attributes(path, followSymlink: true),
                  existing.exists, existing.isDirectory else {
                throw error
            }
        }
    }

    /// Enumerate a remote tree breadth-first. Symlinks are copied as *files* but never descended into: a link back
    /// up the tree would turn a copy into an unbounded walk duplicating half the filesystem.
    public static func walk(_ client: SFTPClient, root: String,
                            shouldContinue: @escaping @Sendable () -> Bool) async throws -> TreePlan {
        var directories: [[String]] = []
        var files: [FileEntry] = []
        var skipped: [String] = []
        var queue: [[String]] = [[]]
        var seen = 0

        while !queue.isEmpty {
            guard shouldContinue() else { throw SFTPError(kind: .aborted, message: "Cancelled") }
            let relative = queue.removeFirst()
            let path = relative.reduce(root, SFTPBrowserPaths.join)
            for entry in try await client.list(path) {
                guard SFTPBrowserPaths.isSafeChildName(entry.name) else {
                    skipped.append(SFTPBrowserPaths.join(path, entry.name))
                    continue
                }
                seen += 1
                guard seen <= maxWalkEntries else {
                    throw SFTPError(kind: .io,
                                    message: "“\(root)” contains more than \(maxWalkEntries) items, which is more than Goel will walk in one go.")
                }
                let child = relative + [entry.name]
                if entry.isDirectory && !entry.isSymlink {
                    guard child.count <= maxWalkDepth else {
                        throw SFTPError(kind: .io,
                                        message: "“\(root)” nests deeper than \(maxWalkDepth) levels, which is more than Goel will walk.")
                    }
                    directories.append(child)
                    queue.append(child)
                } else if !entry.isDirectory {
                    files.append(FileEntry(relative: child, size: entry.size))
                }
            }
        }
        return TreePlan(directories: directories, files: files, skipped: skipped)
    }

    /// Fail if a walk had to leave anything out, so a partial result is never presented as a complete
    /// one — the same policy the local folder scanner applies.
    public static func requireComplete(_ plan: TreePlan) throws {
        guard let first = plan.skipped.first else { return }
        let others = plan.skipped.count - 1
        throw SFTPError(kind: .io,
                        message: "The server listed an item named “\(first)”\(others > 0 ? " and \(others) more" : "") that Goel can’t handle safely, so nothing was transferred.")
    }

    // MARK: Destination naming

    /// Resolve `name` against what already exists in `directory`, per `policy`.
    /// Returns nil when the policy is `.fail` and the name is taken.
    public static func resolvedName(_ name: String, in directory: String,
                                    on client: SFTPClient,
                                    policy: Collision) async throws -> String? {
        let existing = Set(try await client.list(directory).map(\.name))
        guard existing.contains(name) else { return name }
        switch policy {
        case .rename:   return SFTPBrowserPaths.uniqueName(name, existing: existing)
        case .overwrite: return name
        case .fail:     return nil
        }
    }
}
