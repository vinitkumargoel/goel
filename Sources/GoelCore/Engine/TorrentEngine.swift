import Foundation
import TorrentBridge

/// A real BitTorrent engine backed by libtorrent (via the `TorrentBridge` C shim).
///
/// One libtorrent session is created lazily on first use and shared by every
/// torrent. Each task gets a `torrent_handle` plus a polling loop that reads a
/// status snapshot ~once a second and folds it into ``EngineEvent``s, so the
/// scheduler and UI treat torrents exactly like HTTP/HLS downloads. Magnets
/// resolve metadata through libtorrent's DHT before the file list is known.
public actor TorrentEngine: DownloadEngine {
    public nonisolated let kind: DownloadKind = .torrent

    /// libtorrent resolves a torrent's file list up front and honours per-file
    /// priority, but doesn't expose the HTTP engine's resume-data blobs.
    public nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata, .perFilePriority] }

    private nonisolated let hub = EventHub()

    /// libtorrent session configuration (DHT/LSD/uTP/encryption).
    public struct SessionConfig: Sendable, Equatable {
        public var enableDHT: Bool
        public var enableLSD: Bool
        public var enableUTP: Bool
        public var encryptionMode: String   // "prefer" | "require" | "disable"
        public init(enableDHT: Bool = true, enableLSD: Bool = true,
                    enableUTP: Bool = true, encryptionMode: String = "prefer") {
            self.enableDHT = enableDHT; self.enableLSD = enableLSD
            self.enableUTP = enableUTP; self.encryptionMode = encryptionMode
        }
    }

    private var session: UnsafeMutableRawPointer?
    private var handles: [UUID: UnsafeMutableRawPointer] = [:]
    private var pollers: [UUID: Task<Void, Never>] = [:]
    private var tasks: [UUID: DownloadTask] = [:]
    private var profile: TrafficProfile
    private var config: SessionConfig

    public init(profile: TrafficProfile, config: SessionConfig = SessionConfig()) {
        self.profile = profile
        self.config = config
    }

    deinit {
        if let session { gt_session_destroy(session) }
    }

    // MARK: DownloadEngine

    public nonisolated func canHandle(_ source: DownloadSource) -> Bool { source.kind == .torrent }

    public func add(_ task: DownloadTask) async {
        tasks[task.id] = task
        do {
            let handle = try await makeHandle(for: task)
            handles[task.id] = handle
            if task.sequentialDownload == true { gt_set_sequential(handle, 1) }
            if let cap = task.speedLimitBytesPerSec, cap > 0 {
                gt_set_download_limit(handle, Int32(clamping: cap))
            }
            startPoller(task.id)
        } catch {
            let de = (error as? DownloadError) ?? .unknown((error as NSError).localizedDescription)
            emit(task.id, .failed(de))
            emit(task.id, .statusChanged(.failed(de)))
        }
    }

    public func pause(_ id: UUID) async {
        pollers[id]?.cancel(); pollers[id] = nil
        if let handle = handles[id] { gt_pause(handle) }
    }

    public func resume(_ id: UUID) async {
        guard let handle = handles[id] else {
            // Engine was torn down (e.g. after relaunch): re-add from the stored task.
            if let task = tasks[id] { await add(task) }
            return
        }
        gt_resume(handle)
        startPoller(id)
    }

    public func remove(_ id: UUID, deleteData: Bool) async {
        pollers[id]?.cancel(); pollers[id] = nil
        if let session, let handle = handles[id] {
            gt_remove(session, handle, deleteData ? 1 : 0)   // frees the handle wrapper
        } else if let handle = handles[id] {
            gt_handle_free(handle)
        }
        handles[id] = nil
        tasks[id] = nil
        hub.finishAll(id)
    }

    public func applyLimits(_ profile: TrafficProfile) async {
        self.profile = profile
        if let session {
            gt_session_set_rate_limits(session,
                                       Int32(clamping: profile.maxDownloadBytesPerSec),
                                       Int32(clamping: profile.maxUploadBytesPerSec))
            // Wire the profile's peer ceiling into the session so switching to a
            // higher profile actually connects to more peers, not just a wider
            // rate cap. (`connections_limit` was previously left at libtorrent's
            // default regardless of profile.)
            gt_session_set_connections(session, Int32(clamping: profile.maxConnections))
        }
    }

    /// Apply DHT/LSD/uTP/encryption. Takes effect when the session is next
    /// created; an already-running session keeps its current settings.
    public func applySessionConfig(_ config: SessionConfig) { self.config = config }

    /// Apply the engine-agnostic configuration: the torrent engine consumes only
    /// the `.torrent` slice (via the existing ``applySessionConfig(_:)``) and
    /// ignores the HTTP / HLS slices.
    public func configure(_ configuration: EngineConfiguration) async {
        applySessionConfig(configuration.torrent)
    }

    public func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {
        guard let handle = handles[id] else { return }
        gt_set_file_priority(handle, Int32(fileID), Int32(Self.toLibtorrentPriority(priority)))
    }

    public func setSequential(_ sequential: Bool, task id: UUID) async {
        tasks[id]?.sequentialDownload = sequential
        guard let handle = handles[id] else { return }
        gt_set_sequential(handle, sequential ? 1 : 0)
    }

    public nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    // MARK: Metadata preview

    /// Resolve a torrent's metadata (name, total size, file list) **without**
    /// starting a tracked download. The torrent is added to the session only long
    /// enough to fetch its metadata (instant for a `.torrent` file, a DHT/peer
    /// round-trip for a magnet), then removed and any bytes deleted. Used by the
    /// add-confirmation preview so the user sees the files before committing.
    /// Returns nil on timeout, error, or cancellation.
    public func resolveMetadata(
        for source: DownloadSource,
        saveDirectory: String,
        timeout: TimeInterval = 60
    ) async -> (name: String, totalBytes: Int64, files: [TransferFile])? {
        let probe = DownloadTask(source: source, name: "", saveDirectory: saveDirectory)
        guard let handle = try? await makeHandle(for: probe) else { return nil }
        defer {
            if let session { gt_remove(session, handle, 1) } else { gt_handle_free(handle) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            var status = GTStatus()
            if gt_get_status(handle, &status) == 1 {
                if status.state == TorrentState.error.rawValue { return nil }
                if status.has_metadata != 0 {
                    return (Self.cString(status.name), status.total_bytes, readFiles(handle))
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil   // timed out before any peer supplied the metadata
    }

    /// Resolve metadata for the add-confirmation preview through the engine-agnostic
    /// seam, adapting the concrete ``resolveMetadata(for:saveDirectory:timeout:)``.
    /// The torrent name is sanitised here; an empty name lets the manager fold in
    /// its own fallback. Returns nil when no peer supplied metadata in time.
    public func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        guard let m = await resolveMetadata(for: source, saveDirectory: directory) else { return nil }
        let name = m.name.isEmpty ? "" : DownloadTask.sanitizedName(m.name)
        return EngineMetadata(name: name, totalBytes: m.totalBytes, files: m.files)
    }

    // MARK: Session / handle setup

    private func ensureSession() -> UnsafeMutableRawPointer? {
        if let session { return session }
        let policy: Int32 = config.encryptionMode == "disable" ? 0
            : (config.encryptionMode == "require" ? 2 : 1)
        let created = gt_session_create(config.enableDHT ? 1 : 0,
                                        config.enableLSD ? 1 : 0,
                                        config.enableUTP ? 1 : 0,
                                        policy)
        session = created
        if let created {
            gt_session_set_rate_limits(created,
                                       Int32(clamping: profile.maxDownloadBytesPerSec),
                                       Int32(clamping: profile.maxUploadBytesPerSec))
            gt_session_set_connections(created, Int32(clamping: profile.maxConnections))
        }
        return created
    }

    private func makeHandle(for task: DownloadTask) async throws -> UnsafeMutableRawPointer {
        guard let session = ensureSession() else {
            throw DownloadError.unknown("Could not start the BitTorrent session")
        }
        try FileManager.default.createDirectory(atPath: task.saveDirectory, withIntermediateDirectories: true)

        var errBuf = [CChar](repeating: 0, count: 512)
        let saveDir = task.saveDirectory
        let handle: UnsafeMutableRawPointer?

        switch task.source {
        case .magnet(let magnet):
            handle = magnet.withCString { m in
                saveDir.withCString { sp in
                    errBuf.withUnsafeMutableBufferPointer { eb in
                        gt_add_magnet(session, m, sp, eb.baseAddress, 512)
                    }
                }
            }
        case .torrentFile(let url):
            // libtorrent needs a local file; fetch a remote .torrent first.
            let localPath = url.isFileURL ? url.path : try await downloadTorrentFile(url)
            handle = localPath.withCString { fp in
                saveDir.withCString { sp in
                    errBuf.withUnsafeMutableBufferPointer { eb in
                        gt_add_torrent_file(session, fp, sp, eb.baseAddress, 512)
                    }
                }
            }
        default:
            throw DownloadError.unknown("TorrentEngine requires a magnet or .torrent source")
        }

        guard let handle else {
            let message = String(cString: errBuf)
            throw DownloadError.unknown(message.isEmpty ? "Could not add the torrent" : message)
        }
        return handle
    }

    private nonisolated func downloadTorrentFile(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GoelDownloader/torrents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString + ".torrent")
        try data.write(to: file)
        return file.path
    }

    // MARK: Polling

    private func startPoller(_ id: UUID) {
        pollers[id]?.cancel()
        pollers[id] = Task { await self.poll(id) }
    }

    private func poll(_ id: UUID) async {
        var metadataEmitted = false
        var finishedEmitted = false
        var lastPhase: DownloadStatus?

        while !Task.isCancelled {
            guard let handle = handles[id] else { return }
            var status = GTStatus()
            guard gt_get_status(handle, &status) == 1 else { return }

            if !metadataEmitted, status.has_metadata != 0 {
                let files = readFiles(handle)
                emit(id, .metadataResolved(name: Self.cString(status.name),
                                           totalBytes: status.total_bytes, files: files))
                metadataEmitted = true
            }

            emit(id, .progress(bytesDownloaded: status.downloaded_bytes,
                               bytesUploaded: status.uploaded_bytes,
                               downloadSpeed: status.download_rate,
                               uploadSpeed: status.upload_rate,
                               connectionCount: Int(status.num_peers)))
            emit(id, .swarmUpdated(peers: Int(status.num_peers), seeds: Int(status.num_seeds)))
            emit(id, .connectionsUpdated(readPeers(handle)))

            let phase = TorrentState(rawValue: status.state) ?? .downloading
            switch phase {
            case .error:
                let message = Self.cString(status.error)
                let de = DownloadError.network(message.isEmpty ? "Torrent error" : message)
                emit(id, .failed(de))
                emit(id, .statusChanged(.failed(de)))
                pollers[id] = nil
                return
            case .metadata:
                if lastPhase != .requestingMetadata {
                    emit(id, .statusChanged(.requestingMetadata)); lastPhase = .requestingMetadata
                }
            case .checking, .downloading, .queued, .paused:
                if lastPhase != .downloading {
                    emit(id, .statusChanged(.downloading)); lastPhase = .downloading
                }
            case .finished, .seeding:
                if !finishedEmitted {
                    emit(id, .finished)
                    emit(id, .statusChanged(.seeding))
                    finishedEmitted = true
                    lastPhase = .seeding
                }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Read up to 32 connected peers as ``TaskConnection`` rows for the detail
    /// panel. The cap keeps the per-second snapshot bounded on huge swarms.
    private func readPeers(_ handle: UnsafeMutableRawPointer) -> [TaskConnection] {
        var buffer = [GTPeer](repeating: GTPeer(), count: 32)
        let count = Int(buffer.withUnsafeMutableBufferPointer { buf in
            gt_peers(handle, buf.baseAddress, 32)
        })
        guard count > 0 else { return [] }
        return buffer.prefix(count).map { peer in
            let address = Self.cString(peer.address)
            let client = Self.cString(peer.client)
            return TaskConnection(
                id: address,
                label: address,
                detail: client.isEmpty ? "peer" : client,
                downloadSpeed: peer.down_rate,
                uploadSpeed: peer.up_rate,
                progress: peer.progress
            )
        }
    }

    private func readFiles(_ handle: UnsafeMutableRawPointer) -> [TransferFile] {
        let count = Int(gt_file_count(handle))
        guard count > 0 else { return [] }
        var files: [TransferFile] = []
        files.reserveCapacity(count)
        var nameBuf = [CChar](repeating: 0, count: 1024)
        for i in 0..<count {
            var size: Int64 = 0
            var done: Int64 = 0
            var prio: Int32 = 0
            let ok = nameBuf.withUnsafeMutableBufferPointer { buf in
                gt_file_info(handle, Int32(i), buf.baseAddress, 1024, &size, &done, &prio)
            }
            guard ok == 1 else { continue }
            files.append(TransferFile(id: i, path: String(cString: nameBuf), length: size,
                                      bytesCompleted: done,
                                      priority: Self.fromLibtorrentPriority(Int(prio))))
        }
        return files
    }

    // MARK: Helpers

    private func emit(_ id: UUID, _ event: EngineEvent) { hub.emit(id, event) }

    /// Read a fixed C-array tuple field (e.g. `GTStatus.name`) as a Swift String.
    private static func cString<T>(_ tuple: T) -> String {
        withUnsafePointer(to: tuple) { ptr in
            let count = MemoryLayout<T>.size
            return ptr.withMemoryRebound(to: CChar.self, capacity: count) { String(cString: $0) }
        }
    }

    private enum TorrentState: Int32 {
        case queued = 0, checking = 1, metadata = 2, downloading = 3
        case finished = 4, seeding = 5, error = 6, paused = 7
    }

    /// Map our 4-level priority to libtorrent's 0…7 scale.
    static func toLibtorrentPriority(_ p: FilePriority) -> Int {
        switch p {
        case .skip: return 0
        case .low: return 1
        case .normal: return 4
        case .high: return 7
        }
    }

    static func fromLibtorrentPriority(_ value: Int) -> FilePriority {
        switch value {
        case 0: return .skip
        case 1...3: return .low
        case 7: return .high
        default: return .normal
        }
    }
}
