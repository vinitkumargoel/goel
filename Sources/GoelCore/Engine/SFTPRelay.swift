import Foundation
import SSHBridge

/// Source and destination must be *different* connections — one libssh2 session is one thread, sharing deadlocks.
public enum SFTPRelay {

    public enum Collision: Sendable {
        case rename
        case overwrite
        case fail
    }

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

    public static func copyFile(from source: SFTPClient, path sourcePath: String,
                                to destination: SFTPClient, path destinationPath: String,
                                size: Int64,
                                maxBytesPerSecond: Int64 = 0,
                                shouldContinue: @escaping @Sendable () -> Bool = { true },
                                progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let pipe = SFTPRelayPipe()

        // `size` came from a possibly-stale listing; re-read it or a stale 0 truncates the file.
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
                // `streamingDownload` reports failure in its result, never by throwing.
                let result = await source.streamingDownload(
                    remote: sourcePath, resumeFrom: 0, maxBytesPerSecond: maxBytesPerSecond,
                    write: { buf in pipe.write(buf) },
                    progress: { _, _ in shouldContinue() })
                if result.code == GSB_OK {
                    pipe.finish()
                } else {
                    // Must fail the pipe before throwing, else the writer parks on it forever.
                    pipe.fail(result.message)
                    throw result.asError(host: source.target.host, port: source.target.port,
                                         username: source.target.username)
                }
            }
            group.addTask {
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
            do {
                try await group.waitForAll()
            } catch {
                pipe.fail(error.localizedDescription)
                group.cancelAll()
                throw error
            }
        }
    }

    /// Directories must be created shallowest-first so every file has a parent by the time it is written.
    public static func copyTree(from source: SFTPClient, path sourceRoot: String,
                                to destination: SFTPClient, path destinationRoot: String,
                                maxBytesPerSecond: Int64 = 0,
                                shouldContinue: @escaping @Sendable () -> Bool = { true },
                                onFileStart: @escaping @Sendable (String, Int64) -> Void = { _, _ in },
                                onFileProgress: @escaping @Sendable (String, Int64) -> Void = { _, _ in }) async throws {
        let plan = try await walk(source, root: sourceRoot, shouldContinue: shouldContinue)
        try requireComplete(plan)
        try requireNoLinks(plan, root: sourceRoot)

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

    public static func treeSize(_ client: SFTPClient, path root: String,
                                shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws -> Int64 {
        try await walk(client, root: root, shouldContinue: shouldContinue)
            .files.reduce(0) { $0 + $1.size }
    }

    /// SFTP's rmdir refuses non-empty directories, so the tree is emptied first:
    /// files and symlinks, then directories deepest-first, then the root itself.
    /// `onProgress` reports (removed, planned) counts.
    public static func removeTree(_ client: SFTPClient, path root: String,
                                  shouldContinue: @escaping @Sendable () -> Bool = { true },
                                  onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws {
        let plan = try await walk(client, root: root, shouldContinue: shouldContinue)
        try requireComplete(plan, action: "deleted")
        let planned = plan.files.count + plan.links.count + plan.directories.count + 1
        var removed = 0

        func remove(_ relative: [String], isDirectory: Bool) async throws {
            guard shouldContinue() else { throw SFTPError(kind: .aborted, message: "Cancelled") }
            try await client.remove(relative.reduce(root, SFTPBrowserPaths.join),
                                    isDirectory: isDirectory)
            removed += 1
            onProgress(removed, planned)
        }

        for file in plan.files { try await remove(file.relative, isDirectory: false) }
        // A symlink is unlinked like a file even when it points at a directory.
        for link in plan.links { try await remove(link, isDirectory: false) }
        for dir in plan.directories.reversed() { try await remove(dir, isDirectory: true) }
        try await remove([], isDirectory: true)
    }

    public struct FileEntry: Sendable {
        public let relative: [String]
        public let size: Int64
    }

    public struct TreePlan: Sendable {
        public let directories: [[String]]   // shallowest first
        public let files: [FileEntry]
        /// Symlinks that resolve to directories: never descended, never copied — but a delete must unlink them.
        public let links: [[String]]
        /// Names refused for carrying path structure — surfaced, never dropped, or a partial copy reports success.
        public let skipped: [String]
    }

    /// Ceilings against an untrusted server's listing: a crafted tree exhausts memory/CPU before a byte moves.
    public static let maxWalkEntries = 500_000
    public static let maxWalkDepth = 128

    /// Existence is re-checked, not inferred — the shim reports permission/quota/collision mkdir failures identically.
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

    /// Symlinks are copied as files, never descended into: a link back up the tree makes the walk unbounded.
    public static func walk(_ client: SFTPClient, root: String,
                            shouldContinue: @escaping @Sendable () -> Bool) async throws -> TreePlan {
        var directories: [[String]] = []
        var files: [FileEntry] = []
        var links: [[String]] = []
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
                } else {
                    links.append(child)
                }
            }
        }
        return TreePlan(directories: directories, files: files, links: links, skipped: skipped)
    }

    public static func requireComplete(_ plan: TreePlan, action: String = "transferred") throws {
        guard let first = plan.skipped.first else { return }
        let others = plan.skipped.count - 1
        throw SFTPError(kind: .io,
                        message: "The server listed an item named “\(first)”\(others > 0 ? " and \(others) more" : "") that Goel can’t handle safely, so nothing was \(action).")
    }

    /// The bridge can read a symlink but not create one, so a copy would drop it and a move would then
    /// delete the original — refuse the whole tree instead of reporting success over a missing link.
    public static func requireNoLinks(_ plan: TreePlan, root: String) throws {
        guard let first = plan.links.first else { return }
        let others = plan.links.count - 1
        throw SFTPError(kind: .io,
                        message: "“\(root)” contains a link at “\(first.reduce(root, SFTPBrowserPaths.join))”\(others > 0 ? " and \(others) more" : "") that Goel can’t recreate, so nothing was transferred.")
    }

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
