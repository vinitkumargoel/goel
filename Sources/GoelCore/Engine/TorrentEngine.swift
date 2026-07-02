import Foundation
import TorrentBridge

/// A real BitTorrent engine backed by libtorrent (via the `TorrentBridge` C shim).
///
/// One libtorrent session is created lazily on first use and shared by every
/// torrent. Each task gets a `torrent_handle` plus a polling loop that reads a
/// status snapshot ~once a second and folds it into ``EngineEvent``s, so the
/// scheduler and UI treat torrents exactly like HTTP/HLS downloads. Magnets
/// resolve metadata through libtorrent's DHT before the file list is known.
public actor TorrentEngine: TorrentControlling {
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
            if let up = task.uploadLimitBytesPerSec, up > 0 {
                gt_set_upload_limit(handle, Int32(clamping: up))
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

    /// Apply the session-level BitTorrent settings, mapping the shared
    /// ``TorrentSessionConfig`` onto libtorrent's internal ``SessionConfig`` (the
    /// engine consumes DHT / LPD / uTP / encryption; PeX isn't wired to the shim).
    public func configure(_ session: TorrentSessionConfig) async {
        applySessionConfig(SessionConfig(
            enableDHT: session.enableDHT,
            enableLSD: session.enableLPD,
            enableUTP: session.enableUTP,
            encryptionMode: session.encryptionMode))
    }

    public func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {
        // Keep the engine's own task copy current so that a fresh poll (e.g. after
        // a pause→resume in the same session) re-applies the LIVE priority, not the
        // add-time one, and drop the file from the one-shot skip set so it is never
        // silently re-skipped.
        if let f = tasks[id]?.files.firstIndex(where: { $0.id == fileID }) {
            tasks[id]?.files[f].priority = priority
        }
        tasks[id]?.initialSkipFileIDs?.removeAll { $0 == fileID }
        guard let handle = handles[id] else { return }
        gt_set_file_priority(handle, Int32(fileID), Int32(Self.toLibtorrentPriority(priority)))
    }

    public func setSequential(_ sequential: Bool, task id: UUID) async {
        tasks[id]?.sequentialDownload = sequential
        guard let handle = handles[id] else { return }
        gt_set_sequential(handle, sequential ? 1 : 0)
    }

    public func forceRecheck(_ id: UUID) async {
        guard let handle = handles[id] else { return }
        gt_force_recheck(handle)
    }

    public func forceReannounce(_ id: UUID) async {
        guard let handle = handles[id] else { return }
        gt_force_reannounce(handle)
    }

    public func setUploadLimit(_ bytesPerSec: Int64?, task id: UUID) async {
        let cap = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
        tasks[id]?.uploadLimitBytesPerSec = cap
        guard let handle = handles[id] else { return }
        gt_set_upload_limit(handle, Int32(clamping: cap ?? 0))
    }

    public func setSeedRatioLimit(_ ratio: Double?, task id: UUID) async {
        // Stored on the task and enforced in the poll loop (libtorrent has no
        // per-torrent ratio cap in its simple API): once seeding reaches the
        // ratio, the poller pauses the torrent and marks it completed.
        tasks[id]?.seedRatioLimit = (ratio ?? 0) > 0 ? ratio : nil
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
        var tick = 0

        while !Task.isCancelled {
            guard let handle = handles[id] else { return }
            var status = GTStatus()
            guard gt_get_status(handle, &status) == 1 else { return }

            if !metadataEmitted, status.has_metadata != 0 {
                // Apply any pre-add file selection (skip/priority) BEFORE reading
                // the file list back, so the emitted files reflect the user's
                // choice rather than libtorrent's default-normal for every file.
                applyStoredFilePriorities(id, handle)
                let files = readFiles(handle)
                emit(id, .metadataResolved(name: Self.cString(status.name),
                                           totalBytes: status.total_bytes, files: files))
                if let hash = readInfoHash(handle) { emit(id, .infoHashResolved(hash)) }
                metadataEmitted = true
            }

            emit(id, .progress(bytesDownloaded: status.downloaded_bytes,
                               bytesUploaded: status.uploaded_bytes,
                               downloadSpeed: status.download_rate,
                               uploadSpeed: status.upload_rate,
                               connectionCount: Int(status.num_peers)))
            emit(id, .swarmUpdated(peers: Int(status.num_peers), seeds: Int(status.num_seeds)))
            emit(id, .connectionsUpdated(readPeers(handle)))

            // Piece availability and tracker state change more slowly than the
            // byte counters — sample them less often to keep the per-second poll
            // cheap on large torrents/swarms.
            if metadataEmitted, tick % 2 == 0 {
                let pieces = readPieces(handle)
                if !pieces.isEmpty { emit(id, .piecesUpdated(pieces)) }
            }
            if tick % 5 == 0 {
                emit(id, .trackersUpdated(readTrackers(handle)))
            }

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
                // Per-task seed-ratio limit: stop seeding once the target ratio is
                // reached, then mark the task completed (its payload is already on
                // disk). No limit set → seed indefinitely, as before.
                if let limit = tasks[id]?.seedRatioLimit, limit > 0, status.downloaded_bytes > 0 {
                    let ratio = Double(status.uploaded_bytes) / Double(status.downloaded_bytes)
                    if ratio >= limit {
                        gt_pause(handle)
                        emit(id, .statusChanged(.completed))
                        pollers[id] = nil
                        return
                    }
                }
            }

            tick &+= 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Apply the stored per-file selection to a freshly-resolved handle, so it
    /// takes effect before any of those files download. Covers two sources: files
    /// carried on a resumed task that already hold a non-normal priority, and the
    /// `initialSkipFileIDs` a user deselected on the add screen (before the file
    /// list existed on the task).
    private func applyStoredFilePriorities(_ id: UUID, _ handle: UnsafeMutableRawPointer) {
        if let files = tasks[id]?.files {
            for file in files where file.priority != .normal {
                gt_set_file_priority(handle, Int32(file.id),
                                     Int32(Self.toLibtorrentPriority(file.priority)))
            }
        }
        if let skip = tasks[id]?.initialSkipFileIDs {
            for fid in skip {
                gt_set_file_priority(handle, Int32(fid), Int32(Self.toLibtorrentPriority(.skip)))
            }
            // One-shot: the skip is now reflected in the handle (and, once
            // `readFiles` runs, in the persisted per-file priorities). Clear it so a
            // later poll on this same handle — a pause→resume starts a brand-new
            // poll() with `metadataEmitted` reset — cannot re-skip a file the user
            // has since re-enabled.
            tasks[id]?.initialSkipFileIDs = nil
        }
    }

    /// Read the torrent's v1 info-hash (hex), or nil before it is known.
    private func readInfoHash(_ handle: UnsafeMutableRawPointer) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        let ok = buf.withUnsafeMutableBufferPointer { gt_info_hash(handle, $0.baseAddress, 64) }
        guard ok == 1 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }

    /// Read up to 64 trackers with their live announce/scrape state.
    private func readTrackers(_ handle: UnsafeMutableRawPointer) -> [TorrentTracker] {
        var buffer = [GTTracker](repeating: GTTracker(), count: 64)
        let count = Int(buffer.withUnsafeMutableBufferPointer { gt_trackers(handle, $0.baseAddress, 64) })
        guard count > 0 else { return [] }
        return buffer.prefix(count).map { t in
            TorrentTracker(
                url: Self.cString(t.url),
                tier: Int(t.tier),
                message: Self.cString(t.message),
                seeds: t.num_seeds >= 0 ? Int(t.num_seeds) : nil,
                leeches: t.num_leeches >= 0 ? Int(t.num_leeches) : nil,
                status: TorrentTracker.Status(rawValue: Int(t.status)) ?? .inactive,
                verified: t.verified != 0
            )
        }
    }

    /// Read the real piece bitfield and downsample it to `buckets` availability
    /// fractions (0…1) for the Progress-tab grid. Huge torrents are capped and
    /// averaged so the read stays cheap.
    private func readPieces(_ handle: UnsafeMutableRawPointer, buckets: Int = 120) -> [Double] {
        guard gt_piece_count(handle) > 0 else { return [] }
        // gt_pieces downsamples the FULL piece bitfield into up to `buckets`
        // fractional (0…255) availability values on the C++ side, so the map
        // represents the whole torrent regardless of its piece count.
        var vals = [UInt8](repeating: 0, count: buckets)
        let n = Int(vals.withUnsafeMutableBufferPointer { gt_pieces(handle, $0.baseAddress, Int32(buckets)) })
        guard n > 0 else { return [] }
        return vals.prefix(n).map { Double($0) / 255.0 }
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
