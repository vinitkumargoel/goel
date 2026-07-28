import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#else
import CryptoBridge
#endif

actor HLSEngine: HLSConfigurable {
    public nonisolated let kind: DownloadKind = .hls

    nonisolated var capabilities: EngineCapabilities { [] }

    private nonisolated let hub = EventHub()
    nonisolated let session: URLSession
    private nonisolated let userAgent: String

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var profile: TrafficProfile
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
        // Foundation replays hand-set Cookie/Referer/auth headers across a 30x to ANY host; the sanitizer stops that.
        self.session = URLSession(configuration: config,
                                  delegate: RedirectSanitizer.shared, delegateQueue: nil)
    }

    public nonisolated func canHandle(_ source: DownloadSource) -> Bool { source.kind == .hls }

    func add(_ task: DownloadTask) async {
        tasks[task.id] = task
        startJob(task.id)
    }

    func pause(_ id: UUID) async {
        // Cancel but KEEP `jobs[id]`: the next `startJob` serializes on this handle so pause→resume can't double up.
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
        // Wait for writers to stop before unlinking.
        await job?.value
        try? FileManager.default.removeItem(at: Self.workDir(for: id))
        if deleteData, let task, task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
    }

    func applyLimits(_ profile: TrafficProfile) async { self.profile = profile }

    func setMaxHeight(_ height: Int) { maxHeight = max(0, height) }

    func configure(maxHeight: Int) async {
        setMaxHeight(maxHeight)
    }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        EngineMetadata(name: "", totalBytes: nil, isEstimatedSize: true)
    }

    nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    private func startJob(_ id: UUID) {
        // Cancel alone does not wait for exit, so two producers could run against the same workDir.
        let previous = jobs[id]
        previous?.cancel()
        let height = maxHeight
        let bound = max(1, min(8, profile.maxConnectionsPerServer == 0 ? 6 : profile.maxConnectionsPerServer))
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
            let plan = try await resolveMediaPlaylist(playlistURL, maxHeight: maxHeight, task: task)
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

    private func resolveMediaPlaylist(_ url: URL, maxHeight: Int, task: DownloadTask) async throws -> MediaPlan {
        let text = try await fetchText(url, task: task)
        switch HLSParser.parse(text, baseURL: url) {
        case .master(let variants):
            guard let variant = HLSParser.selectVariant(variants, maxHeight: maxHeight > 0 ? maxHeight : nil) else {
                throw DownloadError.unknown("No playable variant in the HLS master playlist")
            }
            // We cannot mux a separate audio rendition, so fetching this variant alone yields a silent video.
            if variant.hasSeparateAudio, !HLSParser.declaresAudioCodec(variant.codecs) {
                throw DownloadError.unknown("This stream delivers its audio as a separate track that this downloader can’t mux in — the result would be a silent video.")
            }
            let mediaText = try await fetchText(variant.url, task: task)
            guard HLSParser.isFinished(mediaText) else { throw Self.liveStreamRefusal }
            guard case .media(let segs, let initMap, _, let total) =
                    HLSParser.parse(mediaText, baseURL: variant.url) else {
                throw DownloadError.unknown("HLS media playlist had no segments")
            }
            return MediaPlan(segments: segs, initMap: initMap, totalDuration: total, bandwidth: variant.bandwidth,
                             identity: Self.renditionIdentity(variant.url, bandwidth: variant.bandwidth,
                                                              height: variant.height))
        case .media(let segs, let initMap, _, let total):
            guard HLSParser.isFinished(text) else { throw Self.liveStreamRefusal }
            return MediaPlan(segments: segs, initMap: initMap, totalDuration: total, bandwidth: 0,
                             identity: Self.renditionIdentity(url, bandwidth: 0, height: nil))
        case nil:
            throw DownloadError.unknown("Not a valid HLS playlist")
        }
    }

    private nonisolated func produce(id: UUID, task: DownloadTask, plan: MediaPlan,
                                      concurrency: Int, rateCap: Int64) async throws {
        let segments = plan.segments
        guard !segments.isEmpty else { throw DownloadError.unknown("HLS playlist had no segments") }
        // Defense in depth: a sanitisation bypass upstream must not let the destination escape the save directory.
        guard task.isSavePathContained else {
            throw DownloadError.unknown("HLS destination escapes the download folder")
        }

        let estTotal = Self.estimatedBytes(bandwidth: plan.bandwidth, duration: plan.totalDuration)
        hub.emit(id, .metadataResolved(name: task.name, totalBytes: estTotal,
                                       files: [TransferFile(id: 0, path: task.name, length: estTotal)]))

        let workDir = Self.workDir(for: id)
        try Self.prepareWorkDir(workDir, identity: plan.identity)

        let keyCache = KeyCache()
        let progress = ProgressTracker(hub: hub, id: id, connections: concurrency)
        let limiter: RateLimiter? = rateCap > 0 ? RateLimiter(bytesPerSecond: rateCap) : nil

        if let initMap = plan.initMap {
            try Task.checkCancellation()
            let initFile = workDir.appendingPathComponent("init.mp4")
            if Self.fileSize(initFile) == nil {
                // Carry the map's own BYTERANGE and key: under CMAF packaging an unranged GET pulls the whole stream.
                let data = try await fetchSegment(HLSSegment(url: initMap.url, duration: 0, sequence: 0,
                                                             key: initMap.key,
                                                             byteRange: initMap.byteRange),
                                                  task: task, keyCache: keyCache,
                                                  requiresExplicitIV: true)
                try data.write(to: initFile)
                if let limiter { await limiter.pace(data.count) }
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var started = 0
            let prime = min(concurrency, segments.count)
            while started < prime {
                let i = started; started += 1
                group.addTask { try await self.downloadSegment(index: i, segment: segments[i],
                                                               task: task, workDir: workDir, keyCache: keyCache,
                                                               progress: progress, limiter: limiter) }
            }
            while started < segments.count {
                try await group.next()
                let i = started; started += 1
                group.addTask { try await self.downloadSegment(index: i, segment: segments[i],
                                                               task: task, workDir: workDir, keyCache: keyCache,
                                                               progress: progress, limiter: limiter) }
            }
            try await group.waitForAll()
        }

        try Task.checkCancellation()

        var parts: [URL] = []
        if plan.initMap != nil { parts.append(workDir.appendingPathComponent("init.mp4")) }
        for i in 0..<segments.count {
            parts.append(workDir.appendingPathComponent(Self.segmentName(i)))
        }

        let destURL = URL(fileURLWithPath: task.savePath)
        try? FileManager.default.removeItem(at: destURL)
        if plan.initMap != nil {
            try Self.concatenate(parts, to: destURL)
        } else {
            let tsURL = workDir.appendingPathComponent("combined.ts")
            try Self.concatenate(parts, to: tsURL)
            try await Self.remuxToMP4(from: tsURL, to: destURL)
        }

        // Never fall back to the estimate: a concat/remux that produced nothing would report as complete.
        guard let actual = Self.fileSize(destURL) else {
            throw DownloadError.unknown("The assembled HLS file is empty — the stream produced no playable output")
        }
        hub.emit(id, .metadataResolved(name: task.name, totalBytes: actual,
                                       files: [TransferFile(id: 0, path: task.name, length: actual)]))
        hub.emit(id, .progress(bytesDownloaded: actual, bytesUploaded: 0,
                               downloadSpeed: 0, uploadSpeed: 0, connectionCount: 0))

        if let expected = task.expectedChecksum {
            hub.emit(id, .statusChanged(.verifying))
            let matched = try await ChecksumVerifier.verify(fileAt: destURL, expected: expected)
            guard matched else { throw DownloadError.checksumMismatch }
        }

        try? FileManager.default.removeItem(at: workDir)
        hub.complete(id)
        await clearJob(id)
    }

    private nonisolated func downloadSegment(index: Int, segment: HLSSegment, task: DownloadTask,
                                             workDir: URL,
                                             keyCache: KeyCache, progress: ProgressTracker,
                                             limiter: RateLimiter?) async throws {
        try Task.checkCancellation()
        let dest = workDir.appendingPathComponent(Self.segmentName(index))
        if let existing = Self.fileSize(dest) {
            await progress.add(existing)
            return
        }
        let data = try await fetchSegment(segment, task: task, keyCache: keyCache)
        // Write to a .part then rename so an interrupted write never looks complete.
        let tmp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        try data.write(to: tmp)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        await progress.add(Int64(data.count))
        if let limiter { await limiter.pace(data.count) }
    }

    /// `requiresExplicitIV`: the fMP4 init map has no sequence number to derive an IV from (RFC 8216 §4.3.2.5).
    private nonisolated func fetchSegment(_ segment: HLSSegment, task: DownloadTask,
                                          keyCache: KeyCache,
                                          requiresExplicitIV: Bool = false) async throws -> Data {
        let raw = try await fetchData(segment.url, task: task, range: segment.byteRange)
        guard let key = segment.key else { return raw }
        switch key.method {
        case .none:
            return raw
        case .unsupported(let method):
            throw DownloadError.unknown("This stream uses \(method) encryption, which this downloader can’t decrypt")
        case .aes128:
            guard let keyURL = key.url else { throw DownloadError.unknown("HLS AES key has no URI") }
            let keyData = try await keyCache.key(for: keyURL) { try await self.fetchData($0, task: task) }
            let iv: Data
            if let explicit = key.iv {
                iv = explicit
            } else if requiresExplicitIV {
                throw DownloadError.unknown("This stream's encrypted fMP4 header declares no IV, so it can’t be decrypted")
            } else {
                iv = Self.iv(forSequence: segment.sequence)
            }
            guard keyData.count == 16, iv.count == 16,
                  let decrypted = Self.aes128CBCDecrypt(raw, key: keyData, iv: iv) else {
                throw DownloadError.unknown("HLS segment decryption failed")
            }
            return decrypted
        }
    }

    /// Every HLS fetch goes through here; ``DownloadTask/outboundHeaders(for:)`` scopes cookies host-exactly.
    nonisolated func makeRequest(_ url: URL, task: DownloadTask,
                                 range: HLSByteRange? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in task.outboundHeaders(for: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let referer = task.referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        // Last-byte math is overflow-checked; an inexpressible range is left off rather than sent wrong.
        if let range, range.start >= 0, range.length > 0 {
            let (last, overflow) = range.start.addingReportingOverflow(range.length - 1)
            if !overflow {
                request.setValue("bytes=\(range.start)-\(last)", forHTTPHeaderField: "Range")
            }
        }
        return request
    }

    private nonisolated func fetchData(_ url: URL, task: DownloadTask,
                                       range: HLSByteRange? = nil) async throws -> Data {
        let request = makeRequest(url, task: task, range: range)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            // A ranged fetch must be answered 206: a server ignoring `Range` would splice its whole body in as one segment.
            guard SegmentedTransfer.classify(http.statusCode, ranged: range != nil) == .accept else {
                throw DownloadError.httpStatus(http.statusCode)
            }
        }
        if let range, data.count != range.length {
            throw DownloadError.unknown("HLS byte-range request returned \(data.count) bytes, expected \(range.length)")
        }
        return data
    }

    private nonisolated func fetchText(_ url: URL, task: DownloadTask) async throws -> String {
        let data = try await fetchData(url, task: task)
        // Past a few MB this is an error page or a hostile body, and decoding it to `String` doubles the cost.
        guard data.count <= Self.maxPlaylistBytes else {
            throw DownloadError.unknown("The HLS playlist is implausibly large (\(Int64(data.count).byteString)) — refusing to parse it")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func emit(_ id: UUID, _ event: EngineEvent) { hub.emit(id, event) }

    private static func segmentName(_ index: Int) -> String { String(format: "seg-%06d.bin", index) }

    private static let maxPlaylistBytes = 8 * 1024 * 1024

    static let liveStreamRefusal = DownloadError.unknown(
        "This is a live HLS stream (no #EXT-X-ENDLIST). Only finished (VOD) streams can be downloaded — the file would stop at whatever part had been published.")

    /// Guarded because `#EXTINF:inf` or an `Int64`-overflowing product would trap; 0 means unknown.
    static func estimatedBytes(bandwidth: Int, duration: Double) -> Int64 {
        guard bandwidth > 0, duration.isFinite, duration > 0 else { return 0 }
        let bytes = Double(bandwidth) / 8.0 * duration
        guard bytes.isFinite, bytes < Double(Int64.max) else { return 0 }
        return Int64(bytes)
    }

    private static func workDir(for id: UUID) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GoelDownloader/hls/\(id.uuidString)", isDirectory: true)
    }

    /// Cached segments are keyed by playlist position, so resume is safe only for the same rendition.
    static func renditionIdentity(_ url: URL, bandwidth: Int, height: Int?) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return "\(components?.string ?? url.absoluteString)|bw=\(bandwidth)|h=\(height ?? 0)"
    }

    /// Discards what a *different* rendition left behind: splicing two of them breaks the file silently.
    static func prepareWorkDir(_ workDir: URL, identity: String) throws {
        let stamp = workDir.appendingPathComponent("rendition.id")
        let recorded = try? String(contentsOf: stamp, encoding: .utf8)
        if recorded != identity, FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try identity.write(to: stamp, atomically: true, encoding: .utf8)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 0 else { return nil }
        return size
    }

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

    /// Default AES-128 IV: the sequence number as a 128-bit big-endian integer, low 64 bits last.
    static func iv(forSequence sequence: Int) -> Data {
        var iv = [UInt8](repeating: 0, count: 16)
        var be = UInt64(bitPattern: Int64(sequence)).bigEndian
        withUnsafeBytes(of: &be) { raw in
            for i in 0..<8 { iv[8 + i] = raw[i] }
        }
        return Data(iv)
    }

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
        // `aac_adtstoasc` rewrites AAC-in-TS for MP4; `+faststart` moves the moov atom up to stay streamable.
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
        // Drain stderr WHILE ffmpeg runs: reading after termination deadlocks once it fills the ~64 KB pipe.
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
    static let ffmpegPath: String = {
        // GOEL_FFMPEG is attacker-influenceable: honour it only as a concrete absolute executable, never a $PATH name.
        if let p = ProcessInfo.processInfo.environment["GOEL_FFMPEG"],
           ProcessSafety.isSafeExecutable(p) { return p }
        for c in ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "/usr/bin/ffmpeg"
    }()
    #endif

    struct MediaPlan: Sendable {
        var segments: [HLSSegment]
        var initMap: HLSInitMap?
        var totalDuration: Double
        var bandwidth: Int
        var identity: String
    }

    private actor KeyCache {
        private var keys: [URL: Data] = [:]
        func key(for url: URL, fetch: @Sendable (URL) async throws -> Data) async throws -> Data {
            if let cached = keys[url] { return cached }
            let data = try await fetch(url)
            keys[url] = data
            return data
        }
    }

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
            let tick = meter.step(total: 0, sofar: bytes, now: Date())
            guard let progress = tick.progress else { return }
            hub.emit(id, .progress(bytesDownloaded: progress.bytes, bytesUploaded: 0,
                                   downloadSpeed: progress.speed, uploadSpeed: 0, connectionCount: connections))
        }
    }
}
