import Foundation

enum RemoteTransferPrep {

    struct Opened: Sendable {
        let handle: FileHandle
        let resumeFrom: Int64
        let fileURL: URL
    }

    static func openForResume(
        saveDirectory: String,
        savePath: String,
        remoteSize: Int64?
    ) throws -> Opened {
        let fm = FileManager.default
        try fm.createDirectory(atPath: saveDirectory, withIntermediateDirectories: true)
        let fileURL = URL(fileURLWithPath: savePath)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        // A stat that merely hiccups (external/network volume, ACL re-check, TOCTOU) is indistinguishable
        // from "empty" once it collapses to 0 — and that 0 drives the truncate below, so a 2 GB partial
        // would silently restart at 0%. Fail the attempt instead: retrying costs nothing, the bytes don't.
        guard let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
              let localSize = (attributes[.size] as? NSNumber)?.int64Value else {
            throw DownloadError.unknown(
                "Couldn’t read the size of “\(fileURL.lastPathComponent)”, so Goel can’t tell how much of it is already downloaded")
        }
        var resumeFrom = localSize
        // A nil `remoteSize` means "the server didn't say", never zero — judging the partial against an
        // unknown size is what would throw the partial away.
        if let remoteSize, remoteSize >= 0, localSize > remoteSize {
            resumeFrom = 0
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw DownloadError.fileMissing
        }
        do {
            // Swallowing these leaves the write position wrong, which appends the resumed bytes at the
            // wrong offset and corrupts the file with no error anywhere.
            if resumeFrom == 0 {
                try handle.truncate(atOffset: 0)
            } else {
                _ = try handle.seekToEnd()
            }
        } catch {
            try? handle.close()
            throw DownloadError.unknown(
                "Couldn’t position “\(fileURL.lastPathComponent)” for writing: \(error.localizedDescription)")
        }
        return Opened(handle: handle, resumeFrom: resumeFrom, fileURL: fileURL)
    }

    static func finishWithOptionalChecksum(
        hub: EventHub,
        id: UUID,
        name: String,
        fileURL: URL,
        written: Int64,
        expected: Checksum?
    ) async {
        hub.emit(id, .metadataResolved(name: name, totalBytes: written,
                                       files: [TransferFile(id: 0, path: name, length: written)]))
        hub.emit(id, .progress(bytesDownloaded: written, bytesUploaded: 0,
                               downloadSpeed: 0, uploadSpeed: 0, connectionCount: 0))
        if let expected {
            hub.emit(id, .statusChanged(.verifying))
            // Only a real digest comparison may say "mismatch": the user may delete a good file over it.
            let matches: Bool
            do {
                matches = try await ChecksumVerifier.verify(fileAt: fileURL, expected: expected)
            } catch is CancellationError {
                return   // paused/removed mid-verify; the manager owns the state
            } catch {
                hub.fail(id, DownloadError.unknown(
                    "Couldn’t verify “\(name)”: \(error.localizedDescription)"))
                return
            }
            if Task.isCancelled { return }
            guard matches else {
                hub.fail(id, DownloadError.checksumMismatch)
                return
            }
        }
        hub.complete(id)
    }

    /// Setup failures keep their cause: "couldn't create the folder" for ENOSPC or EACCES sends users the wrong way.
    static func prepFailure(_ error: Error, saveDirectory: String, log: GoelLogger) -> DownloadError {
        if let de = error as? DownloadError { return de }
        log.error("couldn't prepare the download destination",
                  .path(saveDirectory), .detail(String(describing: error)))
        if isDiskFull(error) { return diskFull(at: saveDirectory, needed: nil) }
        return .unknown("Couldn’t prepare “\(saveDirectory)”: \(error.localizedDescription)")
    }

    /// A local write failure must not surface as the transport's "failure writing output" network error.
    static func writeFailure(_ error: Error, fileURL: URL, needed: Int64?, log: GoelLogger) -> DownloadError {
        log.error("local write failed", .path(fileURL.path), .detail(String(describing: error)))
        if isDiskFull(error) {
            return diskFull(at: fileURL.deletingLastPathComponent().path, needed: needed)
        }
        return .unknown("Couldn’t write “\(fileURL.lastPathComponent)”: \(error.localizedDescription)")
    }

    static func isDiskFull(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSCocoaErrorDomain, e.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return true }
            if e.domain == NSPOSIXErrorDomain, e.code == Int(ENOSPC) || e.code == Int(EDQUOT) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func diskFull(at directory: String, needed: Int64?) -> DownloadError {
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: directory)[.systemFreeSize]
                    as? NSNumber)?.int64Value ?? 0
        return .diskFull(needed: max(needed ?? 0, 0), available: free)
    }

    /// "Remove and delete file" for every engine. The row goes either way — but a delete that fails
    /// (read-only share, file held open by a scanner) must not read as success, or the user is told the
    /// bytes are gone while they still fill the disk.
    static func removeSavedFile(hub: EventHub, id: UUID, task: DownloadTask) {
        do {
            try trashOrDelete(URL(fileURLWithPath: task.savePath))
        } catch {
            // Only a file that survives the attempt is a real failure: a task removed before it ever wrote
            // has nothing to delete, and reporting that would cry wolf on every queued row.
            guard FileManager.default.fileExists(atPath: task.savePath) else { return }
            hub.fail(id, DownloadError.unknown(
                "Removed “\(task.name)” from the list, but its file is still on disk: \(error.localizedDescription)"))
        }
    }

    /// The Trash keeps a mis-click recoverable; a volume without one (or Linux) falls back to unlinking.
    static func trashOrDelete(_ url: URL) throws {
        #if os(macOS)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return
        } catch where FileManager.default.fileExists(atPath: url.path) {
            // No Trash on this volume: delete below.
        }
        #endif
        try FileManager.default.removeItem(at: url)
    }
}
