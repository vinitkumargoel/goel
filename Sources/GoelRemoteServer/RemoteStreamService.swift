import Foundation
import GoelContracts
import GoelCore

/// Pure stream planning shared by the macOS and Linux remote-control servers.
/// Keeps `streamPlan` / byte-range parse / MIME in one place so the two I/O
/// shells cannot drift (e.g. empty finished files).
public enum RemoteStreamService {

    /// What (and how much) of a task can be streamed right now, or nil.
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

    public static func streamPlan(for task: DownloadTask) -> StreamPlan? {
        if task.status.hasData {
            // Finished payload: multi-file torrents stream their main file. Resolve
            // it through `primaryFilePath`, which rejects an engine-declared file
            // path that would escape the save directory (this path is streamed out
            // over the network, so a traversal here would be an arbitrary-file read).
            let path = task.primaryFilePath
            // The file must exist on disk to be streamable, but a legitimately
            // empty (0-byte) finished payload is still streamable — serve it as
            // an empty body rather than collapsing it into the not-ready path.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return nil
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return StreamPlan(path: path, totalBytes: size, availableBytes: size)
        }
        // In flight: only a single-file sequential torrent has a contiguous,
        // provably-safe prefix. Stay a safety margin behind the write head.
        guard task.sequentialDownload == true, !task.isMultiFile,
              task.status == .downloading || task.status == .verifying,
              let total = task.totalBytes, total > 0 else { return nil }
        let margin: Int64 = 8 * 1024 * 1024
        let available = max(0, task.bytesDownloaded - margin)
        guard available > 0 else { return nil }
        return StreamPlan(path: task.savePath, totalBytes: total, availableBytes: available)
    }

    /// Parse `bytes=start-end` against what exists, clamping an open end.
    public static func parseByteRange(_ header: String, available: Int64) -> (Int64, Int64)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return nil }
        let spec = trimmed.dropFirst("bytes=".count)
            .split(separator: ",")[0]   // first range only; we don't do multipart
        let parts = spec.split(separator: "-", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            // Suffix form: last N bytes.
            guard let n = Int64(parts[1]), n > 0 else { return nil }
            return (max(0, available - n), available - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < available else { return nil }
        let end = Int64(parts[1]).map { min($0, available - 1) } ?? (available - 1)
        return (start, end)
    }

    /// Just enough MIME to make media players happy.
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
