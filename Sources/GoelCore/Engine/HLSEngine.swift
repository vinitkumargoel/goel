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
    /// The session every playlist/key/segment fetch goes through. Internal rather
    /// than private only so the redirect hardening below is directly testable.
    nonisolated let session: URLSession
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
        // Built with the SAME redirect sanitizer the HTTP engine installs.
        // `makeRequest` attaches the task's `Cookie`, `Referer` and custom auth
        // headers to every fetch, and Foundation replays a hand-set header across
        // a redirect to any host — so without the delegate a single 30x hands the
        // user's session credentials to an arbitrary third party.
        self.session = URLSession(configuration: config,
                                  delegate: RedirectSanitizer.shared, delegateQueue: nil)
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

    /// Resolve the source playlist down to a concrete media plan, following one
    /// level of master → variant indirection.
    private func resolveMediaPlaylist(_ url: URL, maxHeight: Int, task: DownloadTask) async throws -> MediaPlan {
        let text = try await fetchText(url, task: task)
        switch HLSParser.parse(text, baseURL: url) {
        case .master(let variants):
            guard let variant = HLSParser.selectVariant(variants, maxHeight: maxHeight > 0 ? maxHeight : nil) else {
                throw DownloadError.unknown("No playable variant in the HLS master playlist")
            }
            // A variant whose audio lives in a separate rendition needs muxing
            // this downloader can't do; fetching it alone yields a silent video,
            // so refuse rather than hand back a file that looks fine until played.
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

        let estTotal = Self.estimatedBytes(bandwidth: plan.bandwidth, duration: plan.totalDuration)
        hub.emit(id, .metadataResolved(name: task.name, totalBytes: estTotal,
                                       files: [TransferFile(id: 0, path: task.name, length: estTotal)]))

        let workDir = Self.workDir(for: id)
        try Self.prepareWorkDir(workDir, identity: plan.identity)

        let keyCache = KeyCache()
        let progress = ProgressTracker(hub: hub, id: id, connections: concurrency)
        // Shared across concurrent segments so aggregate throughput respects the
        // profile/task cap (0 = unlimited → no limiter).
        let limiter: RateLimiter? = rateCap > 0 ? RateLimiter(bytesPerSecond: rateCap) : nil

        // fMP4 init map first, if present.
        if let initMap = plan.initMap {
            try Task.checkCancellation()
            let initFile = workDir.appendingPathComponent("init.mp4")
            if Self.fileSize(initFile) == nil {
                // Carry the map's own BYTERANGE: under CMAF single-file packaging
                // the header is a small slice of the same resource the fragments
                // occupy, and an unranged GET would fetch the whole stream here.
                // The map carries the key that was in force where it appeared —
                // NOT the first segment's, which may be a later `#EXT-X-KEY` (or
                // may encrypt a header the playlist left in plaintext).
                let data = try await fetchSegment(HLSSegment(url: initMap.url, duration: 0, sequence: 0,
                                                             key: initMap.key,
                                                             byteRange: initMap.byteRange),
                                                  task: task, keyCache: keyCache,
                                                  requiresExplicitIV: true)
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

        // Assemble in playlist order.
        var parts: [URL] = []
        if plan.initMap != nil { parts.append(workDir.appendingPathComponent("init.mp4")) }
        for i in 0..<segments.count {
            parts.append(workDir.appendingPathComponent(Self.segmentName(i)))
        }

        let destURL = URL(fileURLWithPath: task.savePath)
        try? FileManager.default.removeItem(at: destURL)
        if plan.initMap != nil {
            // fMP4: init + media fragments are already a valid (fragmented) MP4.
            try Self.concatenate(parts, to: destURL)
        } else {
            // MPEG-TS: concatenate, then remux to MP4 via AVFoundation passthrough.
            let tsURL = workDir.appendingPathComponent("combined.ts")
            try Self.concatenate(parts, to: tsURL)
            try await Self.remuxToMP4(from: tsURL, to: destURL)
        }

        // `fileSize` declines both a missing file and a zero-byte one, so falling
        // back to the ESTIMATE here would report a concat/remux that produced
        // nothing as a completed download of `estTotal` bytes.
        guard let actual = Self.fileSize(destURL) else {
            throw DownloadError.unknown("The assembled HLS file is empty — the stream produced no playable output")
        }
        hub.emit(id, .metadataResolved(name: task.name, totalBytes: actual,
                                       files: [TransferFile(id: 0, path: task.name, length: actual)]))
        hub.emit(id, .progress(bytesDownloaded: actual, bytesUploaded: 0,
                               downloadSpeed: 0, uploadSpeed: 0, connectionCount: 0))

        // Integrity check: the Add sheet offers a checksum field for HLS and the
        // detail panel reports the result, so the check has to actually run. It
        // throws before the work directory is cleared, leaving the segment cache
        // in place for a retry.
        if let expected = task.expectedChecksum {
            hub.emit(id, .statusChanged(.verifying))
            let matched = try await ChecksumVerifier.verify(fileAt: destURL, expected: expected)
            guard matched else { throw DownloadError.checksumMismatch }
        }

        try? FileManager.default.removeItem(at: workDir)
        hub.complete(id)
        await clearJob(id)
    }

    // MARK: Segment fetch / decrypt

    private nonisolated func downloadSegment(index: Int, segment: HLSSegment, task: DownloadTask,
                                             workDir: URL,
                                             keyCache: KeyCache, progress: ProgressTracker,
                                             limiter: RateLimiter?) async throws {
        try Task.checkCancellation()
        let dest = workDir.appendingPathComponent(Self.segmentName(index))
        if let existing = Self.fileSize(dest) {
            await progress.add(existing)   // already downloaded (resume)
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

    /// Fetch one segment and decrypt it when a key applies. `requiresExplicitIV`
    /// is set for the fMP4 init map, which has no sequence number of its own to
    /// derive an IV from (RFC 8216 §4.3.2.5 requires the playlist to state one).
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

    /// Build the request for one HLS fetch (playlist, AES key, init map, segment).
    ///
    /// Every outbound request goes through here so none is sent UA-less — and so
    /// the task's credentials are never silently dropped. Playlists behind a login
    /// are the normal case for HLS, so the captured `Cookie`, the `Referer` and any
    /// custom ``DownloadTask/requestHeaders`` must ride along exactly as they do on
    /// the HTTP engine. Headers are resolved through
    /// ``DownloadTask/outboundHeaders(for:)`` rather than read from
    /// `requestHeaders` directly: that is the one place the host-exact cookie scope
    /// is enforced, and it correctly withholds the cookie when a segment lives on a
    /// different CDN host from the playlist.
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
        // EXT-X-BYTERANGE segments address a slice of a larger resource; request
        // just that byte range (servers answer 206, which `fetchData` requires).
        // The last-byte arithmetic is overflow-checked rather than trusted: the
        // parser bounds every range it produces, but a range built elsewhere must
        // still not be able to trap here. A range we can't express is left off,
        // and the response check downstream then refuses the unranged answer.
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
            // A ranged fetch must be answered 206 — the same acceptance rule the
            // segmented HTTP pump applies. A server that ignores `Range` and
            // returns 200 with the whole resource would otherwise have that entire
            // file written as one segment and spliced into the output. (`.retry`
            // is a rejection here too: HLS has no per-segment retry loop.)
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
        // A playlist is a small text file — a long VOD's runs to a few hundred KB.
        // Anything past a few MB is an error page or a hostile body, and decoding
        // it into a `String` would cost as much memory again as receiving it did.
        guard data.count <= Self.maxPlaylistBytes else {
            throw DownloadError.unknown("The HLS playlist is implausibly large (\(Int64(data.count).byteString)) — refusing to parse it")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func emit(_ id: UUID, _ event: EngineEvent) { hub.emit(id, event) }


    // MARK: Static helpers

    private static func segmentName(_ index: Int) -> String { String(format: "seg-%06d.bin", index) }

    /// Upper bound on a playlist body (8 MB) — see ``fetchText(_:task:)``.
    private static let maxPlaylistBytes = 8 * 1024 * 1024

    /// Refusal for a media playlist that never declares itself finished.
    /// A live stream has no end to download to: the file would stop at whatever
    /// had been published when the walk reached it, and report success.
    static let liveStreamRefusal = DownloadError.unknown(
        "This is a live HLS stream (no #EXT-X-ENDLIST). Only finished (VOD) streams can be downloaded — the file would stop at whatever part had been published.")

    /// The download-size estimate from the variant's advertised bitrate and the
    /// playlist's total duration.
    ///
    /// Guarded rather than computed inline: a playlist can say `#EXTINF:inf`, and
    /// converting a non-finite (or `Int64`-overflowing) product traps the process.
    /// The figure is only an estimate the UI shows as approximate, so an unusable
    /// one is reported as 0 — "unknown" — rather than crashing over cosmetics.
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

    /// A stable identity for the rendition a plan's segments come from.
    ///
    /// Cached segment files are keyed only by their *position* in the playlist, so
    /// the work directory is only safe to resume into when the same rendition is
    /// being fetched — see ``prepareWorkDir(_:identity:)``. The query string is
    /// deliberately excluded: signed CDN URLs carry a token that rotates on every
    /// fetch, and folding it in would make every resume look like a new rendition
    /// and throw away all the progress. Bandwidth and height are folded in so the
    /// packagers that distinguish renditions by query alone still compare unequal.
    static func renditionIdentity(_ url: URL, bandwidth: Int, height: Int?) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return "\(components?.string ?? url.absoluteString)|bw=\(bandwidth)|h=\(height ?? 0)"
    }

    /// Create the per-task work directory, discarding anything a *different*
    /// rendition left behind.
    ///
    /// `pause()` keeps the work directory on purpose so a resume can skip segments
    /// already on disk, but the selected rendition is re-resolved on every start:
    /// the user can change the maximum video height between pause and resume, or
    /// the master playlist's variant list can move. Reusing the old segments then
    /// splices two renditions' elementary streams into one file — the remux either
    /// fails or the video breaks at the join, and the task still reports success.
    /// So the identity is stamped into the directory and a mismatch (including a
    /// directory from a build that predates the stamp) starts over from empty.
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
        /// The fMP4 init segment, carrying its own `BYTERANGE` when the packager
        /// put the movie header inside the same resource as the fragments. The
        /// range has to survive into the plan: fetching the map URL unranged
        /// would pull the entire single-file stream down as the "init segment".
        var initMap: HLSInitMap?
        var totalDuration: Double
        var bandwidth: Int
        /// Identifies the rendition these segments came from, so a resumed work
        /// directory filled by a different rendition is discarded rather than
        /// spliced in. See ``HLSEngine/renditionIdentity(_:bandwidth:height:)``.
        var identity: String
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
