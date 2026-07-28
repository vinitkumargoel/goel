import Foundation
import TorrentBridge

/// A real BitTorrent engine backed by libtorrent (via the `TorrentBridge` C shim). One lazily-created
/// session, shared; each task polls a status snapshot ~1/s into ``EngineEvent``s. Magnets use the DHT.
actor TorrentEngine: TorrentControlling {
    public nonisolated let kind: DownloadKind = .torrent

    /// libtorrent resolves a torrent's file list up front and honours per-file
    /// priority, but doesn't expose the HTTP engine's resume-data blobs.
    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata, .perFilePriority] }

    private nonisolated let hub = EventHub()

    /// libtorrent session configuration (DHT/LSD/PeX/uTP/encryption). PeX is a per-torrent flag with no
    /// settings_pack key, so it is carried here and applied at add time and to every live handle.
    struct SessionConfig: Sendable, Equatable {
        var enableDHT: Bool
        var enableLSD: Bool
        var enablePeX: Bool
        var enableUTP: Bool
        var encryptionMode: String // "prefer" | "require" | "disable"
        init(enableDHT: Bool = true, enableLSD: Bool = true, enablePeX: Bool = true,
                    enableUTP: Bool = true, encryptionMode: String = "prefer") {
            self.enableDHT = enableDHT; self.enableLSD = enableLSD
            self.enablePeX = enablePeX
            self.enableUTP = enableUTP; self.encryptionMode = encryptionMode
        }
    }

    private var session: UnsafeMutableRawPointer?
    private var handles: [UUID: UnsafeMutableRawPointer] = [:]
    private var pollers: [UUID: Task<Void, Never>] = [:]
    private var tasks: [UUID: DownloadTask] = [:]
    private var profile: TrafficProfile
    private var config: SessionConfig
    /// Proxy policy for the remote `.torrent`-file body fetch (see `configure`)
    /// *and*, via ``SwarmProxy``, for the libtorrent swarm itself.
    private var httpProxy = NetworkGuard.ProxySpec()

    init(profile: TrafficProfile, config: SessionConfig = SessionConfig()) {
        self.profile = profile
        self.config = config
    }

    deinit {
        if let session { gt_session_destroy(session) }
    }

    // MARK: DownloadEngine

    nonisolated func canHandle(_ source: DownloadSource) -> Bool { source.kind == .torrent }

    func add(_ task: DownloadTask) async {
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
            hub.fail(task.id, de)
        }
    }

    func pause(_ id: UUID) async {
        pollers[id]?.cancel(); pollers[id] = nil
        if let handle = handles[id] {
            gt_pause(handle)
            // Capture the resume blob while the torrent is quiescent: a paused
            // task is the most likely one to still be paused at the next launch.
            saveResumeData(id)
        }
    }

    func resume(_ id: UUID) async {
        guard let handle = handles[id] else {
            // Engine was torn down (e.g. after relaunch): re-add from the stored task.
            if let task = tasks[id] { await add(task) }
            return
        }
        gt_resume(handle)
        startPoller(id)
    }

    func remove(_ id: UUID, deleteData: Bool) async {
        pollers[id]?.cancel(); pollers[id] = nil
        if let session, let handle = handles[id] {
            gt_remove(session, handle, deleteData ? 1 : 0)   // frees the handle wrapper
        } else if let handle = handles[id] {
            gt_handle_free(handle)
        }
        handles[id] = nil
        tasks[id] = nil
        discardResumeData(id)
        hub.finishAll(id)
    }

    func applyLimits(_ profile: TrafficProfile) async {
        self.profile = profile
        if let session {
            gt_session_set_rate_limits(session,
                                       Int32(clamping: profile.maxDownloadBytesPerSec),
                                       Int32(clamping: profile.maxUploadBytesPerSec))
            // Wire the profile's peer ceiling into the session so a higher profile connects to more
            // peers, not just a wider rate cap (`connections_limit` used to stay at the default).
            gt_session_set_connections(session, Int32(clamping: profile.maxConnections))
        }
    }

    /// Apply DHT/LSD/PeX/uTP/encryption. All are live-changeable, so a running session adopts them
    /// immediately — a Settings toggle used to be stored and then ignored for the app's lifetime.
    func applySessionConfig(_ config: SessionConfig) {
        self.config = config
        guard let session else { return }
        gt_session_apply_settings(session,
                                  config.enableDHT ? 1 : 0,
                                  config.enableLSD ? 1 : 0,
                                  config.enableUTP ? 1 : 0,
                                  encryptionPolicy)
        applySwarmProxy(to: session)
        // PeX has no session-wide switch in libtorrent; every already-running
        // torrent has to be told individually (new adds carry the flag).
        for handle in handles.values { gt_set_pex(handle, config.enablePeX ? 1 : 0) }
    }

    /// Apply the session-level BitTorrent settings, mapping the shared
    /// ``TorrentSessionConfig`` onto libtorrent's internal ``SessionConfig``.
    func configure(_ session: TorrentSessionConfig) async {
        httpProxy = session.proxy
        applySessionConfig(SessionConfig(
            enableDHT: session.enableDHT,
            enableLSD: session.enableLPD,
            enablePeX: session.enablePeX,
            enableUTP: session.enableUTP,
            encryptionMode: session.encryptionMode))
    }

    /// Push the user's proxy choice onto the libtorrent session. An unusable configuration lands as
    /// "no proxy" rather than half-applied, so the swarm's real exit path is never misreported.
    private func applySwarmProxy(to session: UnsafeMutableRawPointer) {
        let setting = SwarmProxy.resolve(httpProxy).setting
        setting.host.withCString { host in
            gt_session_set_proxy(session, setting.kind.rawValue, host,
                                 Int32(clamping: setting.port),
                                 setting.peerConnections ? 1 : 0)
        }
    }

    /// libtorrent's encryption policy constant for the current configuration.
    /// Shared by session creation and the live-apply path so they can't drift.
    private var encryptionPolicy: Int32 {
        switch config.encryptionMode {
        case "disable": return 0
        case "require": return 2
        default: return 1
        }
    }

    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {
        // Keep the engine's task copy current so a fresh poll (e.g. after pause→resume) re-applies the
        // LIVE priority, not the add-time one, and drop the file from the one-shot skip set.
        if let f = tasks[id]?.files.firstIndex(where: { $0.id == fileID }) {
            tasks[id]?.files[f].priority = priority
        }
        tasks[id]?.initialSkipFileIDs?.removeAll { $0 == fileID }
        guard let handle = handles[id] else { return }
        gt_set_file_priority(handle, Int32(fileID), Int32(Self.toLibtorrentPriority(priority)))
    }

    func setSequential(_ sequential: Bool, task id: UUID) async {
        tasks[id]?.sequentialDownload = sequential
        guard let handle = handles[id] else { return }
        gt_set_sequential(handle, sequential ? 1 : 0)
    }

    func forceRecheck(_ id: UUID) async {
        guard let handle = handles[id] else { return }
        gt_force_recheck(handle)
    }

    func forceReannounce(_ id: UUID) async {
        guard let handle = handles[id] else { return }
        gt_force_reannounce(handle)
    }

    func setUploadLimit(_ bytesPerSec: Int64?, task id: UUID) async {
        let cap = (bytesPerSec ?? 0) > 0 ? bytesPerSec : nil
        tasks[id]?.uploadLimitBytesPerSec = cap
        guard let handle = handles[id] else { return }
        gt_set_upload_limit(handle, Int32(clamping: cap ?? 0))
    }

    func setSeedRatioLimit(_ ratio: Double?, task id: UUID) async {
        // Stored on the task and enforced in the poll loop (libtorrent has no per-torrent ratio cap):
        // at the ratio the poller pauses and completes. nil = profile's limit; explicit 0 = seed forever.
        tasks[id]?.seedRatioLimit = ratio
    }

    nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    // MARK: Metadata preview

    /// Resolve metadata (name, size, file list) **without** starting a tracked download: added briefly,
    /// upload-only, into a throwaway dir, removed *without* delete-files. nil on timeout; throws on add.
    func resolveMetadata(
        for source: DownloadSource,
        timeout: TimeInterval = 60
    ) async throws -> (name: String, totalBytes: Int64, files: [TransferFile])? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoelDownloader/preview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let probe = DownloadTask(source: source, name: "", saveDirectory: scratch.path)
        let handle = try await makeHandle(for: probe, metadataOnly: true)
        defer {
            if let session { gt_remove(session, handle, 0) } else { gt_handle_free(handle) }
            try? FileManager.default.removeItem(at: scratch)
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

    /// Resolve metadata for the add-confirmation preview through the engine-agnostic seam. nil when no
    /// peer answered in time; a hard add failure returns unreachable + the real reason. `directory` ignored.
    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        do {
            guard let m = try await resolveMetadata(for: source) else { return nil }
            let name = m.name.isEmpty ? "" : PathSafety.sanitizedName(m.name)
            return EngineMetadata(name: name, totalBytes: m.totalBytes, files: m.files)
        } catch {
            return EngineMetadata(name: "", totalBytes: nil, reachable: false,
                                  failureNote: DownloadError(mapping: error).message)
        }
    }

    // MARK: Session / handle setup

    private func ensureSession() -> UnsafeMutableRawPointer? {
        if let session { return session }
        let created = gt_session_create(config.enableDHT ? 1 : 0,
                                        config.enableLSD ? 1 : 0,
                                        config.enableUTP ? 1 : 0,
                                        encryptionPolicy)
        session = created
        if let created {
            gt_session_set_rate_limits(created,
                                       Int32(clamping: profile.maxDownloadBytesPerSec),
                                       Int32(clamping: profile.maxUploadBytesPerSec))
            gt_session_set_connections(created, Int32(clamping: profile.maxConnections))
            // A session created after `configure` would otherwise run without the
            // user's proxy, announcing to trackers and peers from their real IP.
            applySwarmProxy(to: created)
        }
        return created
    }

    /// Build a libtorrent handle for `task`. `metadataOnly` marks the add as a preview probe: it fails
    /// closed on a torrent already in the session (rather than aliasing it) and fetches no payload.
    private func makeHandle(
        for task: DownloadTask,
        metadataOnly: Bool = false
    ) async throws -> UnsafeMutableRawPointer {
        guard let session = ensureSession() else {
            throw DownloadError.unknown("Could not start the BitTorrent session")
        }
        try FileManager.default.createDirectory(atPath: task.saveDirectory, withIntermediateDirectories: true)

        var mode: Int32 = metadataOnly ? Int32(GT_ADD_METADATA_ONLY.rawValue) : 0
        if !config.enablePeX { mode |= Int32(GT_ADD_DISABLE_PEX.rawValue) }
        var errBuf = [CChar](repeating: 0, count: 512)
        let saveDir = task.saveDirectory
        let handle: UnsafeMutableRawPointer?

        // Fast resume: re-adding from libtorrent's own blob restores the lifetime upload total (and so
        // the share ratio) and skips a re-hash. Real adds only — a preview must not inherit live state.
        if !metadataOnly, let restored = restoreFromResumeData(task, session: session, mode: mode) {
            return restored
        }

        switch task.source {
        case .magnet(let magnet):
            handle = magnet.withCString { m in
                saveDir.withCString { sp in
                    errBuf.withUnsafeMutableBufferPointer { eb in
                        gt_add_magnet(session, m, sp, mode, eb.baseAddress, 512)
                    }
                }
            }
        case .torrentFile(let url):
            // libtorrent needs a local file; fetch a remote .torrent first.
            let isRemote = !url.isFileURL
            let localPath = isRemote ? try await downloadTorrentFile(url) : url.path
            // `gt_add_torrent_file` parses synchronously, so a fetched remote copy (a UUID temp file)
            // is no longer needed. Delete on every exit — success, add failure, or cancelled preview.
            defer { if isRemote { try? FileManager.default.removeItem(atPath: localPath) } }
            handle = localPath.withCString { fp in
                saveDir.withCString { sp in
                    errBuf.withUnsafeMutableBufferPointer { eb in
                        gt_add_torrent_file(session, fp, sp, mode, eb.baseAddress, 512)
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

    private func downloadTorrentFile(_ url: URL) async throws -> String {
        // Fetch the remote `.torrent` via the guarded auto-fetch path: honours the proxy (no real-IP
        // leak), bounds redirects, strips cross-host headers, refuses link-local (cloud metadata).
        guard let data = await NetworkGuard.fetch(url: url, proxy: httpProxy,
                                                  userAgent: "GoelDownloader") else {
            throw DownloadError.network("Could not fetch the .torrent file")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GoelDownloader/torrents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString + ".torrent")
        try data.write(to: file)
        return file.path
    }

    // MARK: Fast resume

    /// Where a task's libtorrent fast-resume blob lives: Application Support rather than the save
    /// folder, so a user's download directory stays exactly the payload they asked for.
    private func resumeFileURL(_ id: UUID) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("GoelDownloader", isDirectory: true)
            .appendingPathComponent("TorrentResume", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        return dir.appendingPathComponent(id.uuidString + ".resume")
    }

    /// Re-add a task from its saved resume blob, or nil when there is none and
    /// the caller should add from the original source instead.
    private func restoreFromResumeData(
        _ task: DownloadTask,
        session: UnsafeMutableRawPointer,
        mode: Int32
    ) -> UnsafeMutableRawPointer? {
        guard let resume = resumeFileURL(task.id),
              FileManager.default.fileExists(atPath: resume.path) else { return nil }
        var errBuf = [CChar](repeating: 0, count: 512)
        let restored = resume.path.withCString { rp in
            task.saveDirectory.withCString { sp in
                errBuf.withUnsafeMutableBufferPointer { eb in
                    gt_add_resume(session, rp, sp, mode, eb.baseAddress, 512)
                }
            }
        }
        if restored == nil {
            GoelLog.engineTorrent.notice("fast-resume rejected; re-adding from source",
                                         .detail(String(cString: errBuf), label: "reason"))
        }
        return restored
    }

    /// Persist libtorrent's fast-resume blob. Best-effort and periodic rather than at quit — AppKit does
    /// not await fire-and-forget work on termination. A timeout leaves the previous blob in place.
    private func saveResumeData(_ id: UUID) {
        guard let session, let handle = handles[id], let url = resumeFileURL(id) else { return }
        _ = url.path.withCString { gt_save_resume_data(session, handle, $0, 2_000) }
    }

    /// Drop a task's resume blob once the task itself is gone, so it can't be
    /// picked up by an unrelated future task or linger forever.
    private func discardResumeData(_ id: UUID) {
        guard let url = resumeFileURL(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Drain libtorrent's alert queue and log any session-level failure (today: a listen socket it could
    /// not open — survivable via the ephemeral port, but previously it went nowhere and never drained).
    private func drainSessionAlerts() {
        guard let session else { return }
        var buf = [CChar](repeating: 0, count: 512)
        let reported = buf.withUnsafeMutableBufferPointer {
            gt_session_last_error(session, $0.baseAddress, 512)
        }
        guard reported == 1 else { return }
        GoelLog.engineTorrent.error("BitTorrent session reported a listen failure",
                                    .detail(String(cString: buf), label: "reason"))
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
            guard gt_get_status(handle, &status) == 1 else {
                // The handle is no longer valid — libtorrent evicted the torrent behind our back. Fail
                // closed, or the row freezes with no error, no slot released, no retry. (`remove` first.)
                hub.fail(id, .unknown("The torrent was removed from the BitTorrent session"))
                pollers[id] = nil
                return
            }

            if !metadataEmitted, status.has_metadata != 0 {
                // Apply any pre-add file selection (skip/priority) BEFORE reading the file list back,
                // so emitted files reflect the user's choice, not libtorrent's default-normal.
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

            // Piece availability and tracker state change more slowly than the byte counters — sample
            // them less often to keep the per-second poll cheap on large torrents/swarms.
            if metadataEmitted, tick % 2 == 0 {
                let pieces = readPieces(handle)
                if !pieces.isEmpty { emit(id, .piecesUpdated(pieces)) }
            }
            if tick % 5 == 0 {
                emit(id, .trackersUpdated(readTrackers(handle)))
                drainSessionAlerts()
            }

            let phase = TorrentState(rawValue: status.state) ?? .downloading
            switch phase {
            case .error:
                let message = Self.cString(status.error)
                let de = DownloadError.network(message.isEmpty ? "Torrent error" : message)
                hub.fail(id, de)
                pollers[id] = nil
                return
            case .metadata:
                if lastPhase != .requestingMetadata {
                    emit(id, .statusChanged(.requestingMetadata)); lastPhase = .requestingMetadata
                }
            case .checking, .downloading, .queued:
                if lastPhase != .downloading {
                    emit(id, .statusChanged(.downloading)); lastPhase = .downloading
                }
            case .paused:
                // libtorrent pauses torrents itself (a fatal disk error, the seed-ratio stop below).
                // Reporting those as "Downloading" is a stall the user has no way to read.
                if lastPhase != .paused {
                    emit(id, .statusChanged(.paused)); lastPhase = .paused
                }
            case .finished, .seeding:
                if !finishedEmitted {
                    emit(id, .finished)
                    emit(id, .statusChanged(.seeding))
                    finishedEmitted = true
                    lastPhase = .seeding
                    // Completion is the point worth remembering across a relaunch:
                    // it fixes the lifetime upload total the ratio is measured against.
                    saveResumeData(id)
                }
                // Seed-ratio limit: the task's own, else the active profile's global "stop seeding at
                // ratio". Once reached, stop seeding and mark completed (payload is already on disk).
                if let limit = Self.effectiveSeedRatio(task: tasks[id]?.seedRatioLimit,
                                                       profile: profile.seedRatioLimit),
                   status.downloaded_bytes > 0 {
                    let ratio = Double(status.uploaded_bytes) / Double(status.downloaded_bytes)
                    if ratio >= limit {
                        gt_pause(handle)
                        saveResumeData(id)
                        emit(id, .statusChanged(.completed))
                        pollers[id] = nil
                        return
                    }
                }
            }

            // Save fast resume periodically: `all_time_upload` restarts at zero for a torrent added
            // without its blob, and the manager assigns that straight over the persisted total.
            if metadataEmitted, tick > 0, tick % 60 == 0 { saveResumeData(id) }

            tick &+= 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Apply the stored per-file selection to a freshly-resolved handle, before any of those files
    /// download: a resumed task's non-normal priorities, plus `initialSkipFileIDs` from the add screen.
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
            // One-shot: the skip now lives in the handle (and, after `readFiles`, in the persisted
            // priorities). Clear it so a later poll can't re-skip a file the user has since re-enabled.
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

    /// Read the real piece bitfield and downsample it to `buckets` availability fractions (0…1) for the
    /// Progress-tab grid. Huge torrents are capped and averaged so the read stays cheap.
    private func readPieces(_ handle: UnsafeMutableRawPointer, buckets: Int = 120) -> [Double] {
        guard gt_piece_count(handle) > 0 else { return [] }
        // gt_pieces downsamples the FULL piece bitfield into up to `buckets` fractional (0…255) values
        // on the C++ side, so the map represents the whole torrent regardless of its piece count.
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
        // Completed byte counts in one pass: asking `gt_file_info` per file rebuilds the whole vector
        // each time — O(n²) over a torrent's file list, and this runs on the add-screen preview path.
        var progress = [Int64](repeating: 0, count: count)
        let progressCount = Int(progress.withUnsafeMutableBufferPointer { buf in
            gt_file_progress(handle, buf.baseAddress, Int32(count))
        })
        var nameBuf = [CChar](repeating: 0, count: 1024)
        for i in 0..<count {
            var size: Int64 = 0
            var prio: Int32 = 0
            let ok = nameBuf.withUnsafeMutableBufferPointer { buf in
                gt_file_info(handle, Int32(i), buf.baseAddress, 1024, &size, nil, &prio)
            }
            guard ok == 1 else { continue }
            files.append(TransferFile(id: i, path: String(cString: nameBuf), length: size,
                                      bytesCompleted: i < progressCount ? progress[i] : 0,
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

    /// The seed-ratio limit that applies: the task's own, else the active profile's global one. An
    /// explicit `0` on the task means "seed indefinitely"; a profile `0` means no limit. nil = never stop.
    static func effectiveSeedRatio(task: Double?, profile: Double) -> Double? {
        if let task { return task > 0 ? task : nil }
        return profile > 0 ? profile : nil
    }
}

// MARK: - Swarm proxy policy

/// Pure mapping from the user's proxy choice to what libtorrent can do with the torrent swarm, plus the
/// gap to state when the two don't match. Outside the engine so the decision is testable session-free.
public enum SwarmProxy: Sendable {

    /// The subset of libtorrent's `settings_pack::proxy_type_t` we ever set.
    public enum Kind: Int32, Sendable, Equatable {
        case none = 0
        case socks5 = 2
        case http = 4
    }

    /// What gets pushed to the libtorrent session.
    public struct Setting: Sendable, Equatable {
        public var kind: Kind
        public var host: String
        public var port: Int
        /// Whether peer connections — not just tracker announces — go through
        /// the proxy. Only a SOCKS5 proxy can carry them.
        public var peerConnections: Bool
    }

    /// Why a configured proxy doesn't (fully) cover the swarm. Nil when the
    /// swarm really is proxied, or when no proxy was asked for.
    public enum Gap: String, Sendable, Equatable {
        case systemProxyUnsupported = "The system proxy isn’t applied to the torrent swarm — choose a manual SOCKS5 proxy to route peers through it."
        case httpProxyPeersDirect = "An HTTP proxy can only carry tracker traffic — peer connections go out directly."
        case incompleteManual = "The manual proxy is missing a host or port, so the swarm goes out directly."
    }

    /// Decide what to apply and what to admit. Fails closed: a proxy libtorrent cannot honour becomes
    /// "no proxy" *and* a stated gap, rather than a half-applied setting the user would read as private.
    public static func resolve(_ spec: NetworkGuard.ProxySpec) -> (setting: Setting, gap: Gap?) {
        let direct = Setting(kind: .none, host: "", port: 0, peerConnections: false)
        switch spec.mode {
        case "none":
            return (direct, nil)
        case "manual":
            guard !spec.host.isEmpty, spec.port > 0 else { return (direct, .incompleteManual) }
            if spec.type == "socks5" {
                return (Setting(kind: .socks5, host: spec.host, port: spec.port,
                                peerConnections: true), nil)
            }
            // libtorrent explicitly warns against routing peer connections
            // through an HTTP proxy, so trackers follow it and peers don't.
            return (Setting(kind: .http, host: spec.host, port: spec.port,
                            peerConnections: false), .httpProxyPeersDirect)
        default:
            // "system": libtorrent cannot read the OS (or PAC) proxy, so there is
            // nothing honest to apply.
            return (direct, .systemProxyUnsupported)
        }
    }
}
