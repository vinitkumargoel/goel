import Foundation

/// The filesystem seam for *where downloads land*. Engines and the scheduler create
/// directories, create/replace files, and delete them under the user's save area; on
/// the desktop that area is a free-form absolute path, but on iOS/Android it is a
/// sandbox container (or a security-scoped bookmarked URL) the OS mediates. Routing
/// those mutations through this port gives the mobile adapters the single place they
/// need to (a) confirm a path stays inside the container —
/// `PathSafety.isContained(_:within:)` is the intended check — and (b) wrap the
/// access in `startAccessingSecurityScopedResource` / SAF, without any engine having
/// to learn about sandboxing.
///
/// **Scope:** this abstracts *location & lifecycle* — create / replace / remove /
/// existence — not the streaming byte writes. Once a file has been created here in a
/// permitted location, engines keep writing to its `FileHandle` directly: that path
/// is byte-identical on every platform and needs no seam.
public protocol FileStoring: Sendable {
    /// Create `path` and any missing parents (`withIntermediateDirectories`). Throws
    /// on failure, mirroring `FileManager.createDirectory`.
    func createDirectory(atPath path: String) throws
    /// Create an empty file at `path` (its parent must already exist). Returns
    /// whether the file now exists, mirroring `FileManager.createFile`.
    @discardableResult func createFile(atPath path: String) -> Bool
    /// Write `data` to `path`, creating or replacing it. Non-atomic, matching the
    /// engines' prior inline `Data.write(to:)`.
    func write(_ data: Data, toPath path: String) throws
    /// Move/rename `srcPath` to `dstPath`. Throws on failure, mirroring
    /// `FileManager.moveItem` (used for the completed-file rename).
    func moveItem(atPath srcPath: String, toPath dstPath: String) throws
    /// Remove `path` if present; a missing path is not an error (best-effort, like
    /// the prior inline `try? FileManager.removeItem`).
    func removeItem(atPath path: String)
    /// Whether a file or directory exists at `path`.
    func fileExists(atPath path: String) -> Bool
}

/// Production ``FileStoring`` backed by `FileManager.default`, doing exactly what the
/// engines and scheduler did inline before this seam existed: free-form absolute
/// paths, `withIntermediateDirectories`, non-atomic writes. A `struct` — it owns no
/// live resource. It deliberately does *not* enforce containment: the desktop target
/// writes wherever the user points it, unchanged. A future iOS/Android adapter is
/// where `PathSafety.isContained` + security-scoped / SAF access get applied.
public struct LocalFileStore: FileStoring {
    public init() {}

    public func createDirectory(atPath path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @discardableResult
    public func createFile(atPath path: String) -> Bool {
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    public func write(_ data: Data, toPath path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
    }

    public func moveItem(atPath srcPath: String, toPath dstPath: String) throws {
        try FileManager.default.moveItem(atPath: srcPath, toPath: dstPath)
    }

    public func removeItem(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
