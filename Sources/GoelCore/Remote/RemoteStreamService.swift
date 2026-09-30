import Foundation

public enum RemoteStreamService {

    public struct StreamPlan: Sendable, Equatable {
        public var path: String
        public var totalBytes: Int64
        public var availableBytes: Int64

        public init(path: String, totalBytes: Int64, availableBytes: Int64) {
            self.path = path
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
        }
    }

    /// ``streamPlan(for:)``'s verdict without touching the disk — for listings. A finished file that
    /// has since vanished shows as streamable and `/stream` answers 404, which is the honest place.
    public static func isStreamableHint(_ task: DownloadTask) -> Bool {
        if task.status.hasData { return true }
        guard task.sequentialDownload == true, !task.isMultiFile,
              task.status == .downloading || task.status == .verifying,
              let total = task.totalBytes, total > 0 else { return false }
        return task.bytesDownloaded - sequentialMargin > 0
    }

    static let sequentialMargin: Int64 = 8 * 1024 * 1024

    public static func streamPlan(for task: DownloadTask) -> StreamPlan? {
        if task.status.hasData {
            // `primaryFilePath` rejects a path escaping the save directory — this is streamed out, so traversal = file read.
            let path = task.primaryFilePath
            // A legitimately empty (0-byte) finished payload is still streamable; do not collapse it into not-ready.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return nil
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return StreamPlan(path: path, totalBytes: size, availableBytes: size)
        }
        // Only a single-file sequential torrent has a contiguous prefix; stay a margin behind the write head.
        guard task.sequentialDownload == true, !task.isMultiFile,
              task.status == .downloading || task.status == .verifying,
              let total = task.totalBytes, total > 0 else { return nil }
        let available = max(0, task.bytesDownloaded - sequentialMargin)
        guard available > 0 else { return nil }
        return StreamPlan(path: task.savePath, totalBytes: total, availableBytes: available)
    }

    /// nil ends the body. A read error is not EOF: the client was promised Content-Length bytes and
    /// gets a truncated stream, so the operator must at least see why.
    static func readChunk(_ handle: FileHandle, upTo count: Int, path: String,
                          offset: Int64) -> Data? {
        do {
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                GoelLog.remote.notice("Stream ended before the promised length (file shrank?)",
                                      .path(path), .bytes(offset, label: "offset"))
                return nil
            }
            return chunk
        } catch {
            GoelLog.remote.error("Stream read failed; the client gets a truncated body",
                                 .path(path), .bytes(offset, label: "offset"),
                                 .detail(String(describing: error)))
            return nil
        }
    }

    public static func parseByteRange(_ header: String, available: Int64) -> (Int64, Int64)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return nil }
        // `.first`, never subscripting: `bytes=,,,` splits to nothing and would trap on a request any client can send.
        guard let spec = trimmed.dropFirst("bytes=".count)
            .split(separator: ",").first else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let n = Int64(parts[1]), n > 0 else { return nil }
            return (max(0, available - n), available - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < available else { return nil }
        let end = Int64(parts[1]).map { min($0, available - 1) } ?? (available - 1)
        return (start, end)
    }

    public static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        default: return "application/octet-stream"
        }
    }
}
