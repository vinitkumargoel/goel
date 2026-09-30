import Foundation

/// Limits and checks for `POST /api/add-torrent`.
public enum RemoteTorrentUpload {
    public static let maxFileBytes = 10 * 1024 * 1024
    public static let maxTotalBytes = 25 * 1024 * 1024
    public static let maxFiles = 20
    /// Multipart framing on top of the payload: boundaries and part headers, generously.
    static let framingAllowance = 256 * 1024
    /// The largest request (headers + body) the servers will buffer for this one route.
    static let maxRequestBytes = maxTotalBytes + framingAllowance + RemoteRequest.maxHeaderBytes
    public static let path = "/api/add-torrent"

    public enum Failure: Error, Equatable, Sendable {
        case unsupported
        case couldNotSave
        case rejected(String)

        public var message: String {
            switch self {
            case .unsupported: return "This server cannot add .torrent files."
            case .couldNotSave: return "The upload could not be saved on the server."
            case .rejected(let why): return why
            }
        }
    }

    /// A bencoded dictionary starts with `d` and ends with `e`; anything else is not a .torrent.
    /// Deliberately shallow — libtorrent does the real parse — but it stops an HTML error page,
    /// an image or an empty part from ever reaching the engine or the disk.
    static func looksBencoded(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[data.startIndex] == UInt8(ascii: "d")
            && data[data.index(before: data.endIndex)] == UInt8(ascii: "e")
    }

    /// The client-supplied file name, reduced to a safe display stem (no directories, no extension).
    static func displayName(_ raw: String?) -> String {
        // Old browsers send a full Windows path; `sanitizedName` maps `\` to `_`, so split first.
        let leaf = (raw ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let stem = leaf.lowercased().hasSuffix(".torrent") ? String(leaf.dropLast(".torrent".count)) : leaf
        return PathSafety.sanitizedName(String(stem.prefix(120)), fallback: "torrent")
    }
}

/// Where uploaded .torrent files live. They must outlive the request: the engine re-adds from the
/// file whenever libtorrent's fast-resume blob is rejected. Names are server-chosen UUIDs, so a
/// client's file name never becomes a path.
enum RemoteTorrentSpool {

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GoelDownloader", isDirectory: true)
            .appendingPathComponent("RemoteTorrents", isDirectory: true)
    }

    static func write(_ data: Data, into directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(UUID().uuidString + ".torrent")
        guard PathSafety.isContained(file.path, within: directory.path) else {
            throw RemoteTorrentUpload.Failure.couldNotSave
        }
        try data.write(to: file, options: [.withoutOverwriting])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// The file name of a source that is one of our spooled uploads; nil for anything else.
    static func spoolName(_ source: DownloadSource, in directory: URL) -> String? {
        guard case .torrentFile(let url) = source, url.isFileURL,
              url.pathExtension == "torrent",
              url.deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path,
              PathSafety.isContained(url.path, within: directory.path) else { return nil }
        return url.lastPathComponent
    }

    static func isSpooled(_ source: DownloadSource, in directory: URL) -> Bool {
        spoolName(source, in: directory) != nil
    }

    /// Deletes a spooled upload once its task is gone; anything outside the spool is left alone.
    static func discard(_ source: DownloadSource, directory: URL? = defaultDirectory()) {
        guard let directory, isSpooled(source, in: directory), case .torrentFile(let url) = source else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension DownloadManager {
    public func remoteAddTorrent(_ data: Data, named name: String, saveDirectory: String?,
                                 priority: FilePriority, startPaused: Bool) async throws -> UUID? {
        try await remoteAddTorrent(data, named: name, saveDirectory: saveDirectory,
                                   priority: priority, startPaused: startPaused, network: nil)
    }

    public func remoteAddTorrent(_ data: Data, named name: String, saveDirectory: String?,
                                 priority: FilePriority, startPaused: Bool,
                                 network: NetworkSelection?) async throws -> UUID? {
        guard let directory = spoolDirectory else {
            throw RemoteTorrentUpload.Failure.couldNotSave
        }
        // Off the actor: a slow disk must not stall every download's bookkeeping.
        let file: URL
        do {
            file = try await Task.detached(priority: .userInitiated) {
                try RemoteTorrentSpool.write(data, into: directory)
            }.value
        } catch {
            GoelLog.remote.error("Remote torrent upload could not be spooled",
                                 .detail(error.localizedDescription, label: "reason"))
            throw RemoteTorrentUpload.Failure.couldNotSave
        }
        let source = DownloadSource.torrentFile(file)
        let task = add(source: source, saveDirectory: remoteSaveDirectory(saveDirectory),
                       priority: priority, startPaused: startPaused, suggestedName: name,
                       network: network)
        // Deduplicated onto an existing task: our copy is nobody's source.
        if task.source != source { RemoteTorrentSpool.discard(source, directory: directory) }
        return task.id
    }
}
