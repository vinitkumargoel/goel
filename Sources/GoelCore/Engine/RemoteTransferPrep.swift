import Foundation

/// Shared single-file download prep for FTP/SFTP (and similar sequential engines):
/// mkdir, create/open, resume-from-local with optional remote-size clamp, seek/truncate.
enum RemoteTransferPrep {

    struct Opened: Sendable {
        let handle: FileHandle
        let resumeFrom: Int64
        let fileURL: URL
    }

    /// Prepare `savePath` for a sequential byte-offset resume.
    /// - Parameter remoteSize: when known and local size is larger, restart from 0
    ///   (remote replaced/truncated or path held an unrelated larger file).
    static func openForResume(
        saveDirectory: String,
        savePath: String,
        remoteSize: Int64?,
        fileStore: any FileStoring
    ) throws -> Opened {
        try fileStore.createDirectory(atPath: saveDirectory)
        let fileURL = URL(fileURLWithPath: savePath)
        if !fileStore.fileExists(atPath: fileURL.path) {
            fileStore.createFile(atPath: fileURL.path)
        }
        // A metadata read of the existing file's size, not a write — left on
        // `FileManager` directly (the `FileStore` seam abstracts mutations).
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let localSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        var resumeFrom = localSize
        if let remoteSize, remoteSize >= 0, localSize > remoteSize {
            resumeFrom = 0
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw DownloadError.fileMissing
        }
        if resumeFrom == 0 {
            try? handle.truncate(atOffset: 0)
        } else {
            _ = try? handle.seekToEnd()
        }
        return Opened(handle: handle, resumeFrom: resumeFrom, fileURL: fileURL)
    }

    /// Optional checksum then `hub.complete`, shared by FTP/SFTP finish paths.
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
            let matches = (try? await ChecksumVerifier.verify(fileAt: fileURL, expected: expected)) ?? false
            guard matches else {
                hub.fail(id, DownloadError.checksumMismatch)
                return
            }
        }
        hub.complete(id)
    }
}
