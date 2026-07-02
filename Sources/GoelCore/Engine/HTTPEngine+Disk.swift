import Foundation

// MARK: - Disk / filesystem

/// Filesystem preflight and preallocation: directory creation, the free-space
/// gate, and sizing the destination file before segments seek into it. Split out
/// of ``HTTPEngine``; the space gate is `static` and pure so it is unit-testable.
extension HTTPEngine {

    func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func checkDiskSpace(_ directory: String, needed: Int64) throws {
        try Self.validateDiskSpace(directory: directory, needed: needed)
    }

    /// Pure, testable disk-space gate. Rejects absurd sizes (cap), and — crucially
    /// — THROWS when the volume can't be queried instead of silently assuming
    /// unlimited space (which bypassed the guard entirely and let a multi-GB
    /// download start against a full disk).
    static func validateDiskSpace(
        directory: String,
        needed: Int64,
        maxAllowed: Int64 = HTTPEngine.maxDownloadSize
    ) throws {
        guard needed <= maxAllowed else {
            throw DownloadError.unknown("Declared size \(needed.byteString) exceeds the maximum allowed (\(maxAllowed.byteString))")
        }
        #if os(Linux)
        // `volumeAvailableCapacityForImportantUsageKey` is macOS-only; query the
        // filesystem directly for free space on Linux.
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: directory)
        let available = (attrs[.systemFreeSize] as? Int64) ?? 0
        guard available > 0 else { throw DownloadError.diskFull(needed: needed, available: 0) }
        #else
        let url = URL(fileURLWithPath: directory)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw DownloadError.diskFull(needed: needed, available: 0)
        }
        #endif
        if needed > available {
            throw DownloadError.diskFull(needed: needed, available: available)
        }
    }

    func preallocate(_ url: URL, size: Int64) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
}
