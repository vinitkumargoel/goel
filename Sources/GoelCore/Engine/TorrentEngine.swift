import Foundation
import TorrentBridge

actor TorrentEngine: TorrentControlling {
    public nonisolated let kind: DownloadKind = .torrent

    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata, .perFilePriority] }

    private nonisolated let hub = EventHub()

    /// PeX has no settings_pack key: it is a per-torrent flag, applied at add time and per handle.
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
    private var httpProxy = NetworkGuard.ProxySpec()

    init(profile: TrafficProfile, config: SessionConfig = SessionConfig()) {
        self.profile = profile
        self.config = config
    }

    deinit {
        if let session { gt_session_destroy(session) }
    }

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
            saveResumeData(id)
        }
    }

    func resume(_ id: UUID) async {
        guard let handle = handles[id] else {
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
            gt_session_set_connections(session, Int32(clamping: profile.maxConnections))
        }
    }

    func applySessionConfig(_ config: SessionConfig) {
        self.config = config
        guard let session else { return }
        gt_session_apply_settings(session,
                                  config.enableDHT ? 1 : 0,
                                  config.enableLSD ? 1 : 0,
                                  config.enableUTP ? 1 : 0,
                                  encryptionPolicy)
        applySwarmProxy(to: session)
        // PeX has no session-wide switch: every running torrent must be told individually.
        for handle in handles.values { gt_set_pex(handle, config.enablePeX ? 1 : 0) }
    }

    func configure(_ session: TorrentSessionConfig) async {
        httpProxy = session.proxy
        applySessionConfig(SessionConfig(
            enableDHT: session.enableDHT,
            enableLSD: session.enableLPD,
            enablePeX: session.enablePeX,
            enableUTP: session.enableUTP,
            encryptionMode: session.encryptionMode))
    }

    /// An unusable config must land as "no proxy", never half-applied — the exit path must not be misreported.
    private func applySwarmProxy(to session: UnsafeMutableRawPointer) {
        let setting = SwarmProxy.resolve(httpProxy).setting
        setting.host.withCString { host in
            gt_session_set_proxy(session, setting.kind.rawValue, host,
                                 Int32(clamping: setting.port),
                                 setting.peerConnections ? 1 : 0)
        }
    }

    private var encryptionPolicy: Int32 {
        switch config.encryptionMode {
        case "disable": return 0
        case "require": return 2
        default: return 1
        }
    }

    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {
        // Keep the task copy current, else a later poll re-applies the add-time priority.
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
        // Enforced in the poll loop: libtorrent has no per-torrent ratio cap.
        tasks[id]?.seedRatioLimit = ratio
    }

    nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    /// Preview only: the probe must be removed *without* delete-files, or it takes real payload with it.
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
        return nil
    }

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
            // Without this a session created after `configure` announces from the user's real IP.
            applySwarmProxy(to: created)
        }
        return created
    }

    /// `metadataOnly` fails closed on a torrent already in the session rather than aliasing it.
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

        // Real adds only: a preview must not inherit live state from the resume blob.
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
            let isRemote = !url.isFileURL
            let localPath = isRemote ? try await downloadTorrentFile(url) : url.path
            // `gt_add_torrent_file` parses synchronously, so the temp copy is dead on every exit path.
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
        // Must stay on NetworkGuard: proxy honoured, redirects bounded, cross-host headers stripped, link-local refused.
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

    private func resumeFileURL(_ id: UUID) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("GoelDownloader", isDirectory: true)
            .appendingPathComponent("TorrentResume", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        return dir.appendingPathComponent(id.uuidString + ".resume")
    }

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

    /// Periodic, not at quit: AppKit does not await fire-and-forget work on termination.
    private func saveResumeData(_ id: UUID) {
        guard let session, let handle = handles[id], let url = resumeFileURL(id) else { return }
        _ = url.path.withCString { gt_save_resume_data(session, handle, $0, 2_000) }
    }

    private func discardResumeData(_ id: UUID) {
        guard let url = resumeFileURL(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

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
                // Fail closed: libtorrent evicted the torrent, and the row would freeze with no error or retry.
                hub.fail(id, .unknown("The torrent was removed from the BitTorrent session"))
                pollers[id] = nil
                return
            }

            if !metadataEmitted, status.has_metadata != 0 {
                // Must precede readFiles, else the emitted list is libtorrent's default-normal.
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
                if lastPhase != .paused {
                    emit(id, .statusChanged(.paused)); lastPhase = .paused
                }
            case .finished, .seeding:
                if !finishedEmitted {
                    emit(id, .finished)
                    emit(id, .statusChanged(.seeding))
                    finishedEmitted = true
                    lastPhase = .seeding
                    saveResumeData(id)
                }
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

            // Without a saved blob `all_time_upload` restarts at zero and overwrites the persisted total.
            if metadataEmitted, tick > 0, tick % 60 == 0 { saveResumeData(id) }

            tick &+= 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

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
            // One-shot: without clearing, a later poll re-skips a file the user re-enabled.
            tasks[id]?.initialSkipFileIDs = nil
        }
    }

    private func readInfoHash(_ handle: UnsafeMutableRawPointer) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        let ok = buf.withUnsafeMutableBufferPointer { gt_info_hash(handle, $0.baseAddress, 64) }
        guard ok == 1 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }

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

    private func readPieces(_ handle: UnsafeMutableRawPointer, buckets: Int = 120) -> [Double] {
        guard gt_piece_count(handle) > 0 else { return [] }
        // gt_pieces downsamples the FULL bitfield to 0…255 in C++ — this is not the first `buckets` pieces.
        var vals = [UInt8](repeating: 0, count: buckets)
        let n = Int(vals.withUnsafeMutableBufferPointer { gt_pieces(handle, $0.baseAddress, Int32(buckets)) })
        guard n > 0 else { return [] }
        return vals.prefix(n).map { Double($0) / 255.0 }
    }

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
        // One pass: `gt_file_info` per file rebuilds the whole vector each time — O(n²).
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

    private func emit(_ id: UUID, _ event: EngineEvent) { hub.emit(id, event) }

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

    /// A task `0` means "seed indefinitely"; a profile `0` means no limit; nil = never stop.
    static func effectiveSeedRatio(task: Double?, profile: Double) -> Double? {
        if let task { return task > 0 ? task : nil }
        return profile > 0 ? profile : nil
    }
}

public enum SwarmProxy: Sendable {

    /// Raw values are libtorrent's `settings_pack::proxy_type_t` — not ours to renumber.
    public enum Kind: Int32, Sendable, Equatable {
        case none = 0
        case socks5 = 2
        case http = 4
    }

    public struct Setting: Sendable, Equatable {
        public var kind: Kind
        public var host: String
        public var port: Int
        /// Peer connections, not just tracker announces — only SOCKS5 can carry them.
        public var peerConnections: Bool
    }

    public enum Gap: String, Sendable, Equatable {
        case systemProxyUnsupported = "The system proxy isn’t applied to the torrent swarm — choose a manual SOCKS5 proxy to route peers through it."
        case httpProxyPeersDirect = "An HTTP proxy can only carry tracker traffic — peer connections go out directly."
        case incompleteManual = "The manual proxy is missing a host or port, so the swarm goes out directly."
    }

    /// Fails closed: a proxy libtorrent can't honour becomes "no proxy" + a stated gap, never half-applied.
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
            // libtorrent warns against routing peer connections through an HTTP proxy.
            return (Setting(kind: .http, host: spec.host, port: spec.port,
                            peerConnections: false), .httpProxyPeersDirect)
        default:
            // "system": libtorrent cannot read the OS (or PAC) proxy, so there is nothing honest to apply.
            return (direct, .systemProxyUnsupported)
        }
    }
}
