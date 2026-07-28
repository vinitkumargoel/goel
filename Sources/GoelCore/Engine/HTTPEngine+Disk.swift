import Foundation

// MARK: - Disk / filesystem

/// Filesystem preflight for ``HTTPEngine``: directory creation plus a `static`, pure (unit-testable)
/// free-space gate. Destination sizing lives once as ``SegmentedTransfer/preallocate``.
extension HTTPEngine {

    func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func checkDiskSpace(_ directory: String, needed: Int64) throws {
        try Self.validateDiskSpace(directory: directory, needed: needed)
    }

    /// Pure, testable disk-space gate. Caps absurd sizes and THROWS when the volume can't be queried,
    /// rather than assuming unlimited space — that bypass let multi-GB downloads start on a full disk.
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
}
