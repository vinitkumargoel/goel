import Foundation

public enum RemoteStreamService {

    public struct StreamPlan: Sendable, Equatable {
        public var path: String
        public var totalBytes: Int64
        public var availableBytes: Int64
        /// The folder the opened file's real path must stay inside; its own folder when not given.
        public var root: String

        public init(path: String, totalBytes: Int64, availableBytes: Int64, root: String? = nil) {
            self.path = path
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
            self.root = root ?? (path as NSString).deletingLastPathComponent
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
            return StreamPlan(path: path, totalBytes: size, availableBytes: size, root: task.saveDirectory)
        }
        // Only a single-file sequential torrent has a contiguous prefix; stay a margin behind the write head.
        guard task.sequentialDownload == true, !task.isMultiFile,
              task.status == .downloading || task.status == .verifying,
              let total = task.totalBytes, total > 0 else { return nil }
        let available = max(0, task.bytesDownloaded - sequentialMargin)
        guard available > 0 else { return nil }
        return StreamPlan(path: task.savePath, totalBytes: total, availableBytes: available,
                          root: task.saveDirectory)
    }

    /// What `/stream` answers, for both servers: one file, or with `zip=1` a stored archive.
    public enum Resolution {
        case file(StreamPlan, attachmentName: String?)
        case zip([RemoteZipStream.Entry], name: String)
        case refused(status: String, message: String)
    }

    /// Concurrent `/stream` requests that may build a zip; the servers answer 503 past it.
    static let archiveLimit = 2

    /// Decided before ``resolve(query:backend:)``, which is where a history folder gets walked.
    public static func mayBuildArchive(_ query: [String: String]) -> Bool {
        query["zip"] == "1" || query["history"] != nil
    }

    /// `id` (+ `file=<TransferFile.id>` or `zip=1`) serves a queued task; `history=<id>` a finished
    /// entry that may have left the queue. `dl=1` asks for an attachment rather than inline playback.
    public static func resolve(query: [String: String], backend: RemoteBackend) async -> Resolution {
        let notFound = Resolution.refused(status: "404 Not Found", message: "No such download")
        if let historyID = query["history"].flatMap(UUID.init(uuidString:)) {
            guard let entry = await backend.historyEntry(historyID) else { return notFound }
            return await resolveHistory(entry, backend: backend)
        }
        guard let id = query["id"].flatMap(UUID.init(uuidString:)),
              let task = await backend.task(id) else { return notFound }
        if query["zip"] == "1" {
            let entries = zipEntries(for: task)
            guard !entries.isEmpty else {
                return .refused(status: "409 Conflict", message: "Nothing finished to download yet")
            }
            return .zip(entries, name: archiveName(task.name))
        }
        if let raw = query["file"] {
            guard let fileID = Int(raw), let plan = filePlan(for: task, fileID: fileID) else {
                return .refused(status: "409 Conflict", message: "That file isn't finished yet")
            }
            return .file(plan, attachmentName: (plan.path as NSString).lastPathComponent)
        }
        guard let plan = streamPlan(for: task) else {
            return .refused(status: "409 Conflict",
                            message: "Not streamable yet — finish the download or enable sequential mode")
        }
        let name = query["dl"] == "1" ? (plan.path as NSString).lastPathComponent : nil
        return .file(plan, attachmentName: name)
    }

    /// One file of a torrent, by ``TransferFile/id``, once that file alone is complete. Contained in the
    /// save directory for the same reason as ``DownloadTask/primaryFilePath``: this is streamed out.
    public static func filePlan(for task: DownloadTask, fileID: Int) -> StreamPlan? {
        if !task.isMultiFile {
            guard fileID == 0, task.status.hasData else { return nil }
            return streamPlan(for: task)
        }
        guard let file = task.files.first(where: { $0.id == fileID }), file.isWanted,
              file.bytesCompleted >= file.length,
              let path = containedPath(file.path, in: task.saveDirectory),
              let size = regularFileSize(path) else { return nil }
        return StreamPlan(path: path, totalBytes: size, availableBytes: size, root: task.saveDirectory)
    }

    /// Every finished, wanted file, named by its path inside the torrent.
    public static func zipEntries(for task: DownloadTask) -> [RemoteZipStream.Entry] {
        guard task.isMultiFile else {
            let path = task.primaryFilePath
            guard task.status.hasData, let size = regularFileSize(path),
                  let name = archiveEntryName([(path as NSString).lastPathComponent]) else { return [] }
            return [entry(named: name, path: path, size: size, root: task.saveDirectory)]
        }
        return task.files.compactMap { file in
            guard file.isWanted, file.bytesCompleted >= file.length,
                  let path = containedPath(file.path, in: task.saveDirectory),
                  let size = regularFileSize(path),
                  let name = archivePath(path, under: task.saveDirectory) else { return nil }
            return entry(named: name, path: path, size: size, root: task.saveDirectory)
        }
    }

    /// A history entry outlives its task, so its path is judged afresh: resolved once, and that
    /// spelling is what gets checked, walked and opened. It must sit in a folder the portal may save
    /// into, and must not be one of the download roots itself: only the entry's own file or folder.
    static func resolveHistory(_ entry: HistoryEntry, backend: RemoteBackend) async -> Resolution {
        let resolved = normalized(entry.savePath)
        let parent = (resolved as NSString).deletingLastPathComponent
        let base = (resolved as NSString).lastPathComponent
        let roots = Set(await backend.remoteDownloadRoots().map(normalized))
        guard resolved != "/", !base.hasPrefix("."), !roots.contains(resolved),
              await backend.remoteSaveDirectoryAllowed(parent) else {
            return .refused(status: "403 Forbidden", message: "That file is outside the download folders")
        }
        // Stat-ing and walking a network-mounted folder must not stall the server.
        return await Task.detached(priority: .userInitiated) {
            historyResolution(resolved, parent: parent, base: base)
        }.value
    }

    private static func historyResolution(_ path: String, parent: String, base: String) -> Resolution {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .refused(status: "404 Not Found", message: "File missing on disk")
        }
        if isDirectory.boolValue {
            switch folderEntries(path) {
            case .tooLarge(let limit):
                return .refused(status: "413 Content Too Large",
                                message: "This folder is too large to zip (over \(limit) items)")
            case .entries(let entries) where entries.isEmpty:
                return .refused(status: "404 Not Found", message: "The folder is empty")
            case .entries(let entries):
                return .zip(entries, name: archiveName(base))
            }
        }
        guard let size = regularFileSize(path) else {
            return .refused(status: "404 Not Found", message: "File missing on disk")
        }
        return .file(StreamPlan(path: path, totalBytes: size, availableBytes: size, root: parent),
                     attachmentName: base)
    }

    enum FolderWalk: Equatable {
        case entries([RemoteZipStream.Entry])
        /// Refused rather than cut short: a zip silently missing files looks complete.
        case tooLarge(limit: Int)
    }

    /// Plain files only. Symlinks (to files or folders) and hidden items are neither followed nor
    /// zipped; every item looked at counts against `visitLimit`, not just the files kept.
    static func folderEntries(_ root: String, fileLimit: Int = 10_000,
                              visitLimit: Int = 50_000) -> FolderWalk {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return .entries([]) }
        let base = (root as NSString).lastPathComponent
        var out: [RemoteZipStream.Entry] = []
        var visited = 0
        while let relative = walker.nextObject() as? String {
            visited += 1
            guard visited <= visitLimit else { return .tooLarge(limit: visitLimit) }
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeSymbolicLink || (relative as NSString).lastPathComponent.hasPrefix(".") {
                walker.skipDescendants()
                continue
            }
            guard type == .typeRegular else { continue }
            guard out.count < fileLimit else { return .tooLarge(limit: fileLimit) }
            let path = (root as NSString).appendingPathComponent(relative)
            let components = [base] + relative.split(separator: "/").map(String.init)
            guard PathSafety.isContained(path, within: root), let size = regularFileSize(path),
                  let name = archiveEntryName(components) else { continue }
            out.append(entry(named: name, path: path, size: size, root: root))
        }
        return .entries(out)
    }

    private static func entry(named name: String, path: String, size: Int64,
                              root: String) -> RemoteZipStream.Entry {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return RemoteZipStream.Entry(name: name, path: path, size: size, modified: modified ?? Date(),
                                     root: root)
    }

    static func normalized(_ path: String) -> String {
        ((path as NSString).resolvingSymlinksInPath as NSString).standardizingPath
    }

    private static func containedPath(_ relative: String, in directory: String) -> String? {
        let candidate = (directory as NSString).appendingPathComponent(relative)
        return PathSafety.isContained(candidate, within: directory) ? candidate : nil
    }

    /// The name inside the archive: the standardized path below `directory`, so no `..` survives.
    static func archivePath(_ path: String, under directory: String) -> String? {
        let full = (path as NSString).standardizingPath
        let root = (directory as NSString).standardizingPath
        guard full.hasPrefix(root + "/") else { return nil }
        return archiveEntryName(full.dropFirst(root.count + 1).split(separator: "/").map(String.init))
    }

    /// `\` is a separator to Windows unzip tools and control characters garble a listing, so both
    /// become `_`; empty and `.` parts drop out, and any `..` refuses the name outright.
    static func archiveEntryName(_ components: [String]) -> String? {
        var parts: [String] = []
        for component in components {
            var clean = String.UnicodeScalarView()
            for scalar in component.unicodeScalars {
                let unsafe = scalar == "\\" || scalar.properties.generalCategory == .control
                clean.append(unsafe ? "_" : scalar)
            }
            let part = String(clean)
            if part.isEmpty || part == "." { continue }
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// nil for a directory, a symlink or anything missing: only plain files are served.
    static func regularFileSize(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func archiveName(_ name: String) -> String {
        PathSafety.sanitizedName(name, fallback: "download") + ".zip"
    }

    /// `filename` for old clients, `filename*` (RFC 5987) for the real one; neither can carry CR/LF.
    public static func contentDisposition(_ name: String) -> String {
        let fallback = String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && scalar.value >= 0x20 && scalar != "\"" && scalar != "\\" && scalar.value != 0x7F
                ? Character(scalar) : "_"
        })
        // Spelled out: `.alphanumerics` is Unicode-wide and would let `é` through unencoded.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? fallback
        return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }

    /// The response head for a zip; its length is exact because nothing is compressed.
    public static func zipHead(name: String, length: Int64) -> Data {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/zip\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Content-Disposition: \(contentDisposition(name))\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
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
