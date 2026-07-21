import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#else
import CryptoBridge  // OpenSSL-backed AES-128-CBC on Linux
#endif

/// Downloads an HLS (`.m3u8`) video stream into a single playable file.
///
/// Flow: fetch the playlist → if it's a master, pick the best variant → parse the
/// media playlist → download every segment concurrently (decrypting AES-128
/// segments on the fly) → assemble. fMP4 streams (with an `EXT-X-MAP` init
/// segment) concatenate directly into a valid `.mp4`; MPEG-TS streams concatenate
/// to a temp `.ts` and are remuxed to `.mp4` via AVFoundation passthrough.
///
/// Segment files are written under a per-task work directory, so a paused stream
/// resumes by skipping segments already on disk. Conforms to ``DownloadEngine``
/// so the scheduler and UI treat it like any other download.
actor HLSEngine: HLSConfigurable {
    public nonisolated let kind: DownloadKind = .hls

    /// HLS has no cheap up-front probe (size needs a full playlist walk) and no
    /// per-file selection, so it advertises no optional capabilities.
    nonisolated var capabilities: EngineCapabilities { [] }

    private nonisolated let hub = EventHub()
    private nonisolated let session: URLSession
    private nonisolated let userAgent: String

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var profile: TrafficProfile
    /// Preferred maximum video height (0 = best available).
    private var maxHeight: Int = 0

    init(profile: TrafficProfile, userAgent: String = "GoelDownloader/1.0 (macOS)") {
        self.profile = profile
        self.userAgent = userAgent
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        #if !os(Linux)
        config.waitsForConnectivity = true   // get-only in swift-corelibs-foundation
        #endif
        self.session = URLSession(configuration: config)
    }

    // MARK: DownloadEngine

    public nonisolated func canHandle(_ source: DownloadSource) -> Bool { source.kind == .hls }

    func add(_ task: DownloadTask) async {
        tasks[task.id] = task
        startJob(task.id)
    }

    func pause(_ id: UUID) async {
        // Cancel but KEEP `jobs[id]`: cancellation is a request, not an exit, and
        // the next `startJob` serializes on this handle so a rapid pause→resume
        // can't run two producers over the same workDir. Clearing it here would
        // hand the resume a nil predecessor. Mirrors FTP/SFTP.
        jobs[id]?.cancel()
    }

    func resume(_ id: UUID) async {
        guard tasks[id] != nil else { return }
        startJob(id)
    }

    func remove(_ id: UUID, deleteData: Bool) async {
        let job = jobs[id]
        job?.cancel()
        jobs[id] = nil
        let task = tasks[id]
        tasks[id] = nil
        // Wait for writers to stop before unlinking — matches HTTP/FTP/SFTP.
        await job?.value
        try? FileManager.default.removeItem(at: Self.workDir(for: id))
        if deleteData, let task, task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
    }

    func applyLimits(_ profile: TrafficProfile) async { self.profile = profile }

    func setMaxHeight(_ height: Int) { maxHeight = max(0, height) }

    /// Apply the preferred maximum rendition height (0 = best available).
    func configure(maxHeight: Int) async {
        setMaxHeight(maxHeight)
    }

    /// HLS can't cheaply probe size without walking the whole playlist, which the
    /// preview deliberately skips. It surfaces no name and no size, flagging the
    /// size as an estimate so the UI shows it as approximate until the download
    /// settles the exact figure. The manager folds in its own fallback name.
    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        EngineMetadata(name: "", totalBytes: nil, isEstimatedSize: true)
    }

    nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    // MARK: Orchestration

    private func startJob(_ id: UUID) {
        // Serialize like FTP/SFTP: a rapid pause→resume must not run two producers
        // against the same workDir/segments (cancel alone does not wait for exit).
        let previous = jobs[id]
        previous?.cancel()
        let height = maxHeight
        let bound = max(1, min(8, profile.maxConnectionsPerServer == 0 ? 6 : profile.maxConnectionsPerServer))
        // Capture the bandwidth cap at start (same pattern as HTTP/FTP/SFTP).
        let rateCap = tasks[id].map { profile.effectiveDownloadCap(taskLimit: $0.speedLimitBytesPerSec) } ?? 0
        jobs[id] = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await self.run(id, maxHeight: height, concurrency: bound, rateCap: rateCap)
        }
    }

    private func clearJob(_ id: UUID) { jobs[id] = nil }

    private func run(_ id: UUID, maxHeight: Int, concurrency: Int, rateCap: Int64) async {
        guard let task = tasks[id], case .hlsStream(let playlistURL) = task.source else {
            let e = DownloadError.unknown("HLSEngine requires an HLS source")
            hub.fail(id, e)
            return
        }
        emit(id, .statusChanged(.downloading))
        do {
            try Task.checkCancellation()
            let plan = try await resolveMediaPlaylist(playlistURL, maxHeight: maxHeight)
            try await produce(id: id, task: task, plan: plan, concurrency: concurrency, rateCap: rateCap)
        } catch is CancellationError {
            // pause()/remove() cancelled the job; the manager owns the state.
        } catch {
            if Task.isCancelled { return }
            let de = DownloadError(mapping: error)
            hub.fail(id, de)
            jobs[id] = nil
        }
    }

    /// Resolve the source playlist down to a concrete media plan, following one
    /// level of master → variant indirection.
    private func resolveMediaPlaylist(_ url: URL, maxHeight: Int) async throws -> MediaPlan {
        let text = try await fetchText(url)
        switch HLSParser.parse(text, baseURL: url) {
        case .master(let variants):
            guard let variant = HLSParser.selectVariant(variants, maxHeight: maxHeight > 0 ? maxHeight : nil) else {
                throw DownloadError.unknown("No playable variant in the HLS master playlist")
            }
            let mediaText = try await fetchText(variant.url)
            guard case .media(let segs, let mapURL, _, let total) =
                    HLSParser.parse(mediaText, baseURL: variant.url) else {
                throw DownloadError.unknown("HLS media playlist had no segments")
            }
            return MediaPlan(segments: segs, mapURL: mapURL, totalDuration: total, bandwidth: variant.bandwidth)
        case .media(let segs, let mapURL, _, let total):
            return MediaPlan(segments: segs, mapURL: mapURL, totalDuration: total, bandwidth: 0)
        case nil:
            throw DownloadError.unknown("Not a valid HLS playlist")
        }
    }

    /// Download every segment, assemble, and emit completion. `nonisolated` so the
    /// concurrent fetch/decrypt/assemble work runs off the actor; it reaches the
    /// engine only through the thread-safe `hub` and `nonisolated` fetch helpers.
    private nonisolated func produce(id: UUID, task: DownloadTask, plan: MediaPlan,
                                      concurrency: Int, rateCap: Int64) async throws {
        let segments = plan.segments
        guard !segments.isEmpty else { throw DownloadError.unknown("HLS playlist had no segments") }
        // Defense in depth: the destination is derived from a sanitised task name,
        // but assert it stays inside the save directory before any write — the same
        // guard HTTP/FTP/SFTP apply, so a sanitisation bypass upstream still can't
        // let the final `.mp4` (or its temp files) escape the download folder.
        guard task.isSavePathContained else {
            throw DownloadError.unknown("HLS destination escapes the download folder")
        }

        let estTotal = plan.bandwidth > 0 ? Int64(Double(plan.bandwidth) / 8.0 * plan.totalDuration) : 0
        hub.emit(id, .metadataResolved(name: task.name, totalBytes: estTotal,
                                       files: [TransferFile(id: 0, path: task.name, length: estTotal)]))

        let workDir = Self.workDir(for: id)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let keyCache = KeyCache()
        let progress = ProgressTracker(hub: hub, id: id, connections: concurrency)
        // Shared across concurrent segments so aggregate throughput respects the
        // profile/task cap (0 = unlimited → no limiter).
        let limiter: RateLimiter? = rateCap > 0 ? RateLimiter(bytesPerSecond: rateCap) : nil

        // fMP4 init map first, if present.
        if let mapURL = plan.mapURL {
            try Task.checkCancellation()
            let initFile = workDir.appendingPathComponent("init.mp4")
            if Self.fileSize(initFile) == nil {
                let data = try await fetchSegment(HLSSegment(url: mapURL, duration: 0, sequence: 0,
                                                             key: segments.first?.key),
                                                  keyCache: keyCache)
                try data.write(to: initFile)
                if let limiter { await limiter.pace(data.count) }
            }
        }

        // Concurrent segment download with a sliding window of `concurrency`.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var started = 0
            let prime = min(concurrency, segments.count)
            while started < prime {
                let i = started; started += 1
                group.addTask { try await self.downloadSegment(index: i, segment: segments[i],
                                                               workDir: workDir, keyCache: keyCache,
                                                               progress: progress, limiter: limiter) }
            }
            while started < segments.count {
                try await group.next()
                let i = started; started += 1
                group.addTask { try await self.downloadSegment(index: i, segment: segments[i],
                                                               workDir: workDir, keyCache: keyCache,
                                                               progress: progress, limiter: limiter) }
            }
            try await group.waitForAll()
        }

        try Task.checkCancellation()

        // Assemble in playlist order.
        var parts: [URL] = []
        if plan.mapURL != nil { parts.append(workDir.appendingPathComponent("init.mp4")) }
        for i in 0..<segments.count {
            parts.append(workDir.appendingPathComponent(Self.segmentName(i)))
        }

        let destURL = URL(fileURLWithPath: task.savePath)
        try? FileManager.default.removeItem(at: destURL)
        if plan.mapURL != nil {
            // fMP4: init + media fragments are already a valid (fragmented) MP4.
            try Self.concatenate(parts, to: destURL)
        } else {
            // MPEG-TS: concatenate, then remux to MP4 via AVFoundation passthrough.
            let tsURL = workDir.appendingPathComponent("combined.ts")
            try Self.concatenate(parts, to: tsURL)
            try await Self.remuxToMP4(from: tsURL, to: destURL)
        }

        let actual = Self.fileSize(destURL) ?? estTotal
        hub.emit(id, .metadataResolved(name: task.name, totalBytes: actual,
                                       files: [TransferFile(id: 0, path: task.name, length: actual)]))
        hub.emit(id, .progress(bytesDownloaded: actual, bytesUploaded: 0,
                               downloadSpeed: 0, uploadSpeed: 0, connectionCount: 0))
        try? FileManager.default.removeItem(at: workDir)
        hub.complete(id)
        await clearJob(id)
    }

    // MARK: Segment fetch / decrypt

    private nonisolated func downloadSegment(index: Int, segment: HLSSegment, workDir: URL,
                                             keyCache: KeyCache, progress: ProgressTracker,
                                             limiter: RateLimiter?) async throws {
        try Task.checkCancellation()
        let dest = workDir.appendingPathComponent(Self.segmentName(index))
        if let existing = Self.fileSize(dest) {
            await progress.add(existing)   // already downloaded (resume)
            return
        }
        let data = try await fetchSegment(segment, keyCache: keyCache)
        // Write to a .part then rename so an interrupted write never looks complete.
        let tmp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        try data.write(to: tmp)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        await progress.add(Int64(data.count))
        if let limiter { await limiter.pace(data.count) }
    }

    private nonisolated func fetchSegment(_ segment: HLSSegment, keyCache: KeyCache) async throws -> Data {
        let raw = try await fetchData(segment.url, range: segment.byteRange)
        guard let key = segment.key else { return raw }
        switch key.method {
        case .none:
            return raw
        case .sampleAES:
            throw DownloadError.unknown("SAMPLE-AES encrypted streams aren’t supported")
        case .aes128:
            guard let keyURL = key.url else { throw DownloadError.unknown("HLS AES key has no URI") }
            let keyData = try await keyCache.key(for: keyURL) { try await self.fetchData($0) }
            let iv = key.iv ?? Self.iv(forSequence: segment.sequence)
            guard keyData.count == 16, iv.count == 16,
                  let decrypted = Self.aes128CBCDecrypt(raw, key: keyData, iv: iv) else {
                throw DownloadError.unknown("HLS segment decryption failed")
            }
            return decrypted
        }
    }

    private nonisolated func fetchData(_ url: URL, range: HLSByteRange? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // EXT-X-BYTERANGE segments address a slice of a larger resource; request
        // just that byte range (servers answer 206, already within 200...299).
        if let range {
            request.setValue("bytes=\(range.start)-\(range.start + range.length - 1)",
                             forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode)
        }
        return data
    }

    private nonisolated func fetchText(_ url: URL) async throws -> String {
        String(decoding: try await fetchData(url), as: UTF8.self)
    }

    private func emit(_ id: UUID, _ event: EngineEvent) { hub.emit(id, event) }


    // MARK: Static helpers

    private static func segmentName(_ index: Int) -> String { String(format: "seg-%06d.bin", index) }

    private static func workDir(for id: UUID) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GoelDownloader/hls/\(id.uuidString)", isDirectory: true)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 0 else { return nil }
        return size
    }

    /// Concatenate `parts` (in order) into `dest`, streaming part-by-part without
    /// loading whole segments into RAM (large VOD can be multi-100MB).
    private static func concatenate(_ parts: [URL], to dest: URL) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
        }
    }

    /// The default AES-128 IV when none is given: the segment sequence number as a
    /// 128-bit big-endian integer (low 64 bits in the final 8 bytes).
    static func iv(forSequence sequence: Int) -> Data {
        var iv = [UInt8](repeating: 0, count: 16)
        var be = UInt64(bitPattern: Int64(sequence)).bigEndian
        withUnsafeBytes(of: &be) { raw in
            for i in 0..<8 { iv[8 + i] = raw[i] }
        }
        return Data(iv)
    }

    /// AES-128-CBC decrypt with PKCS7 padding (the HLS `AES-128` method).
    static func aes128CBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == 16, iv.count == 16 else { return nil }   // AES-128 block/key size
        let capacity = data.count + 16
        var output = Data(count: capacity)
        #if canImport(CommonCrypto)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
        #else
        // Linux: OpenSSL EVP via CryptoBridge (PKCS7 padding on by default).
        var outLen: Int32 = 0
        let ok = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        gb_aes128_cbc_decrypt(
                            keyPtr.bindMemory(to: UInt8.self).baseAddress,
                            ivPtr.bindMemory(to: UInt8.self).baseAddress,
                            dataPtr.bindMemory(to: UInt8.self).baseAddress, Int32(data.count),
                            outPtr.bindMemory(to: UInt8.self).baseAddress, &outLen)
                    }
                }
            }
        }
        guard ok == 1 else { return nil }
        output.removeSubrange(Int(outLen)..<output.count)
        return output
        #endif
    }

    /// Remux an MPEG-TS file to MP4 by passing the elementary streams through
    /// (no re-encode). Works for the common H.264/AAC case.
    private static func remuxToMP4(from src: URL, to dest: URL) async throws {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadError.unknown("Couldn’t initialise the MP4 converter for this stream")
        }
        export.outputURL = dest
        export.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed {
            throw export.error ?? DownloadError.unknown("HLS → MP4 conversion failed (unsupported codec)")
        }
        #else
        // Linux: remux via ffmpeg (stream copy, no re-encode). `aac_adtstoasc`
        // rewrites AAC-in-TS for the MP4 container; `+faststart` moves the moov
        // atom to the front so the result is streamable.
        let ff = Process()
        ff.executableURL = URL(fileURLWithPath: Self.ffmpegPath)
        ff.arguments = [
            "-y", "-loglevel", "error", "-i", src.path,
            "-c", "copy", "-bsf:a", "aac_adtstoasc",
            "-movflags", "+faststart", dest.path,
        ]
        ff.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        ff.standardError = errPipe
        let errHandle = errPipe.fileHandleForReading
        do {
            try ff.run()
        } catch {
            throw DownloadError.unknown("ffmpeg not found for HLS remux (install ffmpeg): \(error)")
        }
        // Drain stderr on a background thread WHILE ffmpeg runs. Reading it only
        // after termination would deadlock: a chatty ffmpeg (e.g. many per-frame
        // errors on a corrupt segment) fills the ~64 KB pipe, blocks in write(),
        // and never exits — exactly the failure case this remux is meant to report.
        let errData = Task.detached { errHandle.readDataToEndOfFile() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ff.terminationHandler = { _ in c.resume() }
        }
        if ff.terminationStatus != 0 {
            let msg = String(data: await errData.value, encoding: .utf8) ?? ""
            throw DownloadError.unknown("HLS → MP4 conversion failed: \(msg)")
        }
        #endif
    }

    #if os(Linux)
    /// Path to the ffmpeg binary used for HLS remux on Linux.
    static let ffmpegPath: String = {
        // GOEL_FFMPEG comes from the process environment (attacker-influenceable by
        // anything that can set the daemon's env); only honour it when it's a
        // concrete absolute executable, never a bare $PATH name or an interpreter.
        if let p = ProcessInfo.processInfo.environment["GOEL_FFMPEG"],
           ProcessSafety.isSafeExecutable(p) { return p }
        for c in ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "/usr/bin/ffmpeg"
    }()
    #endif

    // MARK: Supporting types

    /// The concrete download plan resolved from the source playlist.
    struct MediaPlan: Sendable {
        var segments: [HLSSegment]
        var mapURL: URL?
        var totalDuration: Double
        var bandwidth: Int
    }

    /// Caches fetched AES keys by URI so a shared key is downloaded once.
    private actor KeyCache {
        private var keys: [URL: Data] = [:]
        func key(for url: URL, fetch: @Sendable (URL) async throws -> Data) async throws -> Data {
            if let cached = keys[url] { return cached }
            let data = try await fetch(url)
            keys[url] = data
            return data
        }
    }

    /// Accumulates downloaded bytes from concurrent segment tasks and emits a
    /// throttled aggregate progress event with a smoothed speed. The throttle +
    /// windowed-speed math is the shared, clock-tested ``TransferProgressMeter``;
    /// this only holds the running total, the event hub, and the fixed connection
    /// count (rather than re-deriving the same 0.2 s throttle + speed guard).
    private actor ProgressTracker {
        private let hub: EventHub
        private let id: UUID
        private let connections: Int
        private var bytes: Int64 = 0
        private var meter = TransferProgressMeter(resumeFrom: 0)

        init(hub: EventHub, id: UUID, connections: Int) {
            self.hub = hub; self.id = id; self.connections = connections
        }

        func add(_ n: Int64) {
            bytes += n
            // HLS streams segments with no aggregate Content-Length, so pass
            // total: 0 — the meter announces a total only once it's known (never,
            // here), and still emits the throttled progress sample.
            let tick = meter.step(total: 0, sofar: bytes, now: Date())
            guard let progress = tick.progress else { return }
            hub.emit(id, .progress(bytesDownloaded: progress.bytes, bytesUploaded: 0,
                                   downloadSpeed: progress.speed, uploadSpeed: 0, connectionCount: connections))
        }
    }
}
