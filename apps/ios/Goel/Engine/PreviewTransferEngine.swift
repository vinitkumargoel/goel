import Foundation

/// A `TransferEngine` that moves no bytes.
///
/// It exists for two reasons, and the second one is the important one:
///
/// 1. SwiftUI previews need populated state without a network.
/// 2. **Every screenshot task in this build compares against `visual.html`.** A real engine
///    produces a different number every run, so there is nothing to compare. This engine
///    reproduces the exact frame in the mockup — 63 %, 48.2 MB/s, 44 s left, six segments at
///    100/78/64/57/41/22 % — and reproduces it identically on every launch.
///
/// Launched with `-uiTestingPreviewEngine`, the app selects ``makeStatic()``, which is frozen:
/// it emits one `.progress` per download and then never changes. ``makeLive()`` advances on a
/// fixed 0.1 s timestep so animation can actually be watched.
///
/// Determinism rules, all load-bearing:
/// - No `Date()` is read anywhere at call time. ``fixtures(now:)`` takes its reference date.
/// - No `Double.random`, no `Hasher` (its seed is per-process). Speeds are a closed-form
///   function of the sample index; ids are fixed byte patterns; sizes are integer arithmetic.
/// - The live simulation advances on a tick *count*, never on elapsed wall-clock time, so a
///   scheduling hiccup cannot change the values it emits.
public actor PreviewTransferEngine: TransferEngine {

    // MARK: - Stream

    /// One multiplexed stream for every download. See ``TransferEngine/events`` — the contract
    /// is a single subscriber.
    ///
    /// Both this and its continuation are immutable `nonisolated let`s established in `init`.
    /// `AsyncStream` and `AsyncStream.Continuation` are both `Sendable`, so this needs no
    /// `@unchecked Sendable` and no `nonisolated(unsafe)`.
    public nonisolated let events: AsyncStream<TransferEvent>
    private nonisolated let continuation: AsyncStream<TransferEvent>.Continuation

    // MARK: - State

    /// Queue order, matching `visual.html` frame 1 top to bottom.
    private var order: [UUID]
    private var downloads: [UUID: Download]
    private let isLive: Bool
    /// Monotonic simulation clock. The live values derive from this, never from `Date()`.
    private var tickCount: Int = 0
    private var ticker: Task<Void, Never>?

    private init(live: Bool, now: Date) {
        // A generous buffer so a pump that subscribes a moment after launch still receives the
        // initial burst rather than dropping it on the floor.
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream(
            of: TransferEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.continuation = continuation
        self.isLive = live

        let seed = PreviewTransferEngine.fixtures(now: now)
        self.order = seed.map(\.id)
        self.downloads = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    deinit {
        // The ticker holds `self` weakly, so it unwinds on its own once this actor is gone.
        continuation.finish()
    }

    /// Frozen. No ticking, no animation, identical on every launch — this is what every
    /// screenshot task uses.
    public static func makeStatic(now: Date = goelPreviewReferenceDate) -> PreviewTransferEngine {
        let engine = PreviewTransferEngine(live: false, now: now)
        Task { await engine.emitInitialProgress() }
        return engine
    }

    /// Advances on a fixed 0.1 s timestep so progress bars, segment bars and the sparkline can
    /// be seen moving. Values still come from the tick counter, not the clock.
    public static func makeLive(now: Date = goelPreviewReferenceDate) -> PreviewTransferEngine {
        let engine = PreviewTransferEngine(live: true, now: now)
        Task { await engine.startTicking() }
        return engine
    }

    // MARK: - Fixtures

    /// The reference instant the fixtures are dated against. A fixed epoch, never `Date()`,
    /// so two runs produce byte-identical values.
    public static var referenceDate: Date { goelPreviewReferenceDate }

    public static var ubuntuID: UUID { goelPreviewFixtureID(0x01) }
    public static var nasBackupID: UUID { goelPreviewFixtureID(0x02) }
    public static var keynoteID: UUID { goelPreviewFixtureID(0x03) }
    public static var datasetID: UUID { goelPreviewFixtureID(0x04) }
    public static var blenderID: UUID { goelPreviewFixtureID(0x05) }

    /// The five downloads from `visual.html`, in queue order.
    ///
    /// Pure and deterministic: same `now` in, byte-identical array out. Nothing here reads the
    /// clock, the environment, or a random source.
    ///
    /// Every byte count is derived by integer arithmetic from the size and percentage printed
    /// in the mockup, so the derived values land on the printed ones rather than near them:
    /// ubuntu is 3 609 902 000 / 5 730 000 000 = 0.630000 with 2.12 GB and 44 s left at
    /// 48.2 MB/s — which is exactly what frames 1, 2 and the Live Activity all show.
    ///
    /// `addedAt` decreases down the array, so a newest-first sort reproduces the mockup's
    /// order as well as the array order does.
    public static func fixtures(now: Date = goelPreviewReferenceDate) -> [Download] {

        // 1 — ubuntu-24.04.1-desktop-amd64.iso · 5.73 GB · 63 % · 48.2 MB/s · 44 s left
        //
        // The six segments are deliberately *not* equal in size. Six equal segments at
        // 100/78/64/57/41/22 % average to 60.3 %, not the 63 % the mockup prints. A real
        // segmented downloader splits the remaining range dynamically and ends up with unequal
        // segments, so the sizes below are weighted to reproduce both numbers at once:
        // the six per-segment percentages are exact, and so is the 63 % total.
        let ubuntuSegments = makeSegments([
            (size: 1_150_900_000, permille: 1000, active: false),  // 100 % — done, drawn green
            (size:   955_000_000, permille:  780, active: true),
            (size:   955_000_000, permille:  640, active: true),
            (size:   955_000_000, permille:  570, active: true),
            (size:   955_000_000, permille:  410, active: true),
            (size:   759_100_000, permille:  220, active: true),
        ])
        let ubuntu = Download(
            id: ubuntuID,
            url: staticURL("https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso"),
            filename: "ubuntu-24.04.1-desktop-amd64.iso",
            saveDirectory: "Goel°/Linux",
            kind: .https,
            status: .downloading,
            totalBytes: 5_730_000_000,
            receivedBytes: total(of: ubuntuSegments),
            segments: ubuntuSegments,
            speedSamples: throughputCurve(peak: 48_200_000, phase: 0),
            addedAt: now.addingTimeInterval(-60),
            checksumVerified: false,
            isSequential: false,
            supportsResume: true,
            validator: "\"5f2c1a90-155e2d3600\""
        )

        // 2 — nas-backup-2026-07-14.tar.zst · 12.6 GB · 31 % · 12.4 MB/s · sftp
        // Four equal segments whose percentages average to exactly 31 %.
        let nasSegments = makeSegments([
            (size: 3_150_000_000, permille: 520, active: true),
            (size: 3_150_000_000, permille: 380, active: true),
            (size: 3_150_000_000, permille: 220, active: true),
            (size: 3_150_000_000, permille: 120, active: true),
        ])
        let nasBackup = Download(
            id: nasBackupID,
            url: staticURL("sftp://nas.local/volume1/backups/nas-backup-2026-07-14.tar.zst"),
            filename: "nas-backup-2026-07-14.tar.zst",
            saveDirectory: "Goel°/Backups",
            kind: .sftp,
            status: .downloading,
            totalBytes: 12_600_000_000,
            receivedBytes: total(of: nasSegments),
            segments: nasSegments,
            speedSamples: throughputCurve(peak: 12_400_000, phase: 17),
            addedAt: now.addingTimeInterval(-420),
            supportsResume: true,
            validator: "\"6a01ff3b-2ee0000000\""
        )

        // 3 — keynote-2026-4k-hdr.mp4 · 2.1 GB · 23 % · sequential, playable now
        // One segment covering the whole file: sequential mode is what makes it playable at
        // 23 %, and that is incompatible with parallel ranges.
        let keynoteSegments = makeSegments([
            (size: 2_100_000_000, permille: 230, active: true),
        ])
        let keynote = Download(
            id: keynoteID,
            url: staticURL("https://cdn.goel.dev/media/keynote-2026-4k-hdr.mp4"),
            filename: "keynote-2026-4k-hdr.mp4",
            saveDirectory: "Goel°/Media",
            kind: .https,
            status: .downloading,
            totalBytes: 2_100_000_000,
            receivedBytes: total(of: keynoteSegments),
            segments: keynoteSegments,
            speedSamples: throughputCurve(peak: 48_200_000, phase: 34),
            addedAt: now.addingTimeInterval(-900),
            isSequential: true,
            supportsResume: true,
            validator: "\"71b4c8de-7d2b740000\""
        )

        // 4 — dataset-imagenet-subset.tar · 18 GB · 8 % · waiting for Wi-Fi
        // No speed samples at all: nothing is moving, so `currentSpeed` is 0 and `eta` is nil.
        // The mockup row prints "Waiting for Wi-Fi · 1.4 of 18 GB" — no rate, no countdown.
        let datasetSegments = makeSegments([
            (size: 4_500_000_000, permille: 140, active: false),
            (size: 4_500_000_000, permille:  90, active: false),
            (size: 4_500_000_000, permille:  50, active: false),
            (size: 4_500_000_000, permille:  40, active: false),
        ])
        let dataset = Download(
            id: datasetID,
            url: staticURL("https://datasets.goel.dev/imagenet/dataset-imagenet-subset.tar"),
            filename: "dataset-imagenet-subset.tar",
            saveDirectory: "Goel°/Datasets",
            kind: .https,
            status: .waitingForWiFi,
            totalBytes: 18_000_000_000,
            receivedBytes: total(of: datasetSegments),
            segments: datasetSegments,
            speedSamples: [],
            addedAt: now.addingTimeInterval(-1_500),
            supportsResume: true,
            validator: "\"7c33a1b8-431ba00000\""
        )

        // 5 — Blender-4.2-macOS-arm64.dmg · 412.3 MB · completed, SHA-256 verified, 2 min ago
        let blenderSegments = makeSegments([
            (size: 103_075_000, permille: 1000, active: false),
            (size: 103_075_000, permille: 1000, active: false),
            (size: 103_075_000, permille: 1000, active: false),
            (size: 103_075_000, permille: 1000, active: false),
        ])
        let blender = Download(
            id: blenderID,
            url: staticURL("https://download.blender.org/release/Blender4.2/Blender-4.2-macOS-arm64.dmg"),
            filename: "Blender-4.2-macOS-arm64.dmg",
            saveDirectory: "Goel°/Apps",
            kind: .https,
            status: .completed,
            totalBytes: 412_300_000,
            receivedBytes: total(of: blenderSegments),
            segments: blenderSegments,
            speedSamples: [],
            addedAt: now.addingTimeInterval(-3_600),
            completedAt: now.addingTimeInterval(-120),
            checksumVerified: true,
            supportsResume: true,
            validator: "\"8d55e2c1-1893cbc0\""
        )

        return [ubuntu, nasBackup, keynote, dataset, blender]
    }

    /// A snapshot of the engine's downloads, in queue order.
    public func currentDownloads() -> [Download] {
        order.compactMap { downloads[$0] }
    }

    // MARK: - TransferEngine

    private static let supportedSchemes: Set<String> = ["http", "https", "ftp", "ftps", "sftp"]

    public func start(_ download: Download) async throws {
        guard let scheme = download.url.scheme?.lowercased(), !scheme.isEmpty else {
            throw TransferError.invalidURL
        }
        guard PreviewTransferEngine.supportedSchemes.contains(scheme) else {
            throw TransferError.unsupportedScheme(scheme)
        }

        var updated = download
        updated.status = .downloading
        updated.errorMessage = nil
        updated.segments = updated.segments.map { segment in
            var segment = segment
            segment.isActive = !segment.isComplete
            return segment
        }
        downloads[updated.id] = updated
        if !order.contains(updated.id) { order.append(updated.id) }

        continuation.yield(.statusChanged(id: updated.id, status: .downloading))
        emitProgress(for: updated)
    }

    public func pause(_ id: UUID) async {
        guard var download = downloads[id], !download.status.isTerminal else { return }
        download.status = .paused
        download.segments = download.segments.map { segment in
            var segment = segment
            segment.isActive = false
            return segment
        }
        downloads[id] = download
        continuation.yield(.statusChanged(id: id, status: .paused))
    }

    public func resume(_ id: UUID) async {
        guard var download = downloads[id], !download.status.isTerminal else { return }
        download.status = .downloading
        download.errorMessage = nil
        download.segments = download.segments.map { segment in
            var segment = segment
            segment.isActive = !segment.isComplete
            return segment
        }
        downloads[id] = download
        continuation.yield(.statusChanged(id: id, status: .downloading))
    }

    /// Marks the download failed with ``TransferError/cancelled``'s message, and discards its
    /// bytes when asked.
    ///
    /// The entry is kept rather than removed: the store owns the queue array, not the engine,
    /// so removing it here would silently desynchronise ``currentDownloads()`` from the store.
    public func cancel(_ id: UUID, deleteData: Bool) async {
        guard var download = downloads[id] else { return }
        download.status = .failed
        download.errorMessage = TransferError.cancelled.userMessage
        if deleteData {
            download.receivedBytes = 0
            download.segments = download.segments.map { segment in
                var segment = segment
                segment.receivedBytes = 0
                segment.isActive = false
                return segment
            }
        } else {
            download.segments = download.segments.map { segment in
                var segment = segment
                segment.isActive = false
                return segment
            }
        }
        download.speedSamples = []
        downloads[id] = download
        continuation.yield(.statusChanged(id: id, status: .failed))
    }

    /// Resolves metadata with no network access whatsoever.
    ///
    /// URLs that match a fixture filename return that fixture's exact size and validator, so
    /// probing the ubuntu link reproduces the add sheet in `visual.html` frame 3 — 5.73 GB,
    /// "Disk Image · resumable". Anything else gets a size derived from an FNV-1a hash of the
    /// URL: arbitrary, but stable across processes, which `Hasher` would not be.
    public func probe(_ url: URL) async throws -> ProbeResult {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty, url.host != nil else {
            throw TransferError.invalidURL
        }
        guard PreviewTransferEngine.supportedSchemes.contains(scheme) else {
            throw TransferError.unsupportedScheme(scheme)
        }

        let raw = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let filename = raw.isEmpty ? "download.bin" : raw
        let mimeType = PreviewTransferEngine.mimeType(forExtension: ProbeResult.fileExtension(of: filename))
        let isPlaylist = ProbeResult.fileExtension(of: filename) == "m3u8"
        let supportsResume = !isPlaylist
        let isStreamable = supportsResume && (mimeType?.hasPrefix("video/") ?? false)

        if let match = PreviewTransferEngine.fixtures().first(where: { $0.filename == filename }) {
            return ProbeResult(
                filename: match.filename,
                totalBytes: match.totalBytes,
                supportsResume: match.supportsResume,
                mimeType: mimeType,
                isStreamable: match.isSequential,
                validator: match.validator
            )
        }

        let hash = PreviewTransferEngine.fnv1a(url.absoluteString)
        return ProbeResult(
            filename: filename,
            totalBytes: isPlaylist ? nil : Int64(1_000_000 + hash % 4_000_000_000),
            supportsResume: supportsResume,
            mimeType: mimeType,
            isStreamable: isStreamable,
            validator: "\"" + String(hash, radix: 16) + "\""
        )
    }

    // MARK: - Simulation

    /// One `.progress` per download, then silence. Everything a frozen screenshot needs.
    private func emitInitialProgress() {
        for download in currentDownloads() {
            emitProgress(for: download)
        }
    }

    private func emitProgress(for download: Download) {
        continuation.yield(
            .progress(
                id: download.id,
                received: download.receivedBytes,
                total: download.totalBytes,
                speed: download.currentSpeed,
                segments: download.segments
            )
        )
    }

    /// The live loop: a fixed 0.1 s timestep, ~10 Hz, driven by a tick counter.
    private func startTicking() {
        guard isLive, ticker == nil else { return }
        emitInitialProgress()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                await self.tick()
            }
        }
    }

    private static let timestep: Double = 0.1

    private func tick() {
        tickCount &+= 1
        for id in order {
            guard var download = downloads[id], download.status == .downloading else { continue }
            guard let total = download.totalBytes else { continue }

            let peak = PreviewTransferEngine.peakSpeed(for: download)
            let speed = PreviewTransferEngine.instantSpeed(peak: peak, phase: PreviewTransferEngine.phase(for: download), tick: tickCount)
            PreviewTransferEngine.advance(&download, by: Int64((speed * PreviewTransferEngine.timestep).rounded()))
            download.recordSpeedSample(speed)
            downloads[id] = download
            emitProgress(for: download)

            if download.receivedBytes >= total {
                download.status = .completed
                download.completedAt = download.addedAt.addingTimeInterval(Double(tickCount) * PreviewTransferEngine.timestep)
                download.checksumVerified = true
                download.segments = download.segments.map { segment in
                    var segment = segment
                    segment.isActive = false
                    return segment
                }
                downloads[id] = download
                continuation.yield(.statusChanged(id: id, status: .completed))
                continuation.yield(.completed(id: id, fileURL: PreviewTransferEngine.destinationURL(for: download)))
            }
        }
    }

    /// Distributes newly received bytes across the active, incomplete segments, spilling any
    /// remainder into whichever segment still has room. Keeps `receivedBytes` equal to the sum
    /// of the segments, which is the invariant `contiguousPrefix` and the segment bars rely on.
    static func advance(_ download: inout Download, by delta: Int64) {
        guard delta > 0 else { return }
        guard !download.segments.isEmpty else {
            let cap = download.totalBytes ?? (download.receivedBytes + delta)
            download.receivedBytes = min(cap, download.receivedBytes + delta)
            return
        }

        var budget = delta
        // Pass one spreads the budget evenly; pass two mops up what a full segment could not take.
        for _ in 0..<2 {
            let open = download.segments.indices.filter {
                download.segments[$0].isActive && !download.segments[$0].isComplete
            }
            guard !open.isEmpty, budget > 0 else { break }
            let share = max(1, budget / Int64(open.count))
            for index in open where budget > 0 {
                let segment = download.segments[index]
                let room = segment.totalBytes - segment.receivedBytes
                guard room > 0 else { continue }
                let take = min(room, min(share, budget))
                download.segments[index].receivedBytes += take
                budget -= take
            }
        }

        for index in download.segments.indices where download.segments[index].isComplete {
            download.segments[index].isActive = false
        }
        let summed = download.segments.reduce(Int64(0)) { $0 + $1.receivedBytes }
        download.receivedBytes = min(summed, download.totalBytes ?? summed)
    }

    private static func peakSpeed(for download: Download) -> Double {
        switch download.id {
        case nasBackupID: 12_400_000
        default: 48_200_000
        }
    }

    private static func phase(for download: Download) -> Double {
        switch download.id {
        case nasBackupID: 17
        case keynoteID: 34
        default: 0
        }
    }

    private static func destinationURL(for download: Download) -> URL {
        var url = URL.documentsDirectory
        if !download.saveDirectory.isEmpty {
            url = url.appending(path: download.saveDirectory, directoryHint: .isDirectory)
        }
        return url.appending(path: download.filename, directoryHint: .notDirectory)
    }

    // MARK: - Deterministic throughput

    /// 60 speed samples — one minute at 1 Hz, exactly what `Download.speedSampleLimit` keeps
    /// and what the detail sparkline in `visual.html` draws.
    ///
    /// Shape: a gentle rise across the minute with a three-term sinusoidal wobble on top, which
    /// gives the sparkline visible structure instead of a straight line. No RNG — a closed-form
    /// function of the sample index, so two calls are bit-identical.
    ///
    /// The tail is then normalised so the **mean of the last three samples** equals `peak`,
    /// because that is precisely how `Download.currentSpeed` is defined. Skip that step and the
    /// ubuntu row prints 46.1 MB/s where the mockup says 48.2.
    static func throughputCurve(
        peak: Double,
        phase: Double,
        count: Int = Download.speedSampleLimit
    ) -> [Double] {
        guard peak > 0, count > 0 else { return [] }
        let span = Double(max(count - 1, 1))
        var shape: [Double] = []
        shape.reserveCapacity(count)
        for index in 0..<count {
            let x = Double(index)
            let trend = 0.62 + 0.34 * (x / span)
            shape.append(max(0.05, trend + wobble(at: x + phase)))
        }

        let tail = shape.suffix(3)
        let tailMean = tail.reduce(0, +) / Double(tail.count)
        guard tailMean.isFinite, tailMean > 0 else {
            return Array(repeating: peak, count: count)
        }
        let scale = peak / tailMean
        return shape.map { $0 * scale }
    }

    /// Instantaneous speed for the live simulation, centred on `peak` so the smoothed
    /// `currentSpeed` stays at the number the mockup prints.
    static func instantSpeed(peak: Double, phase: Double, tick: Int) -> Double {
        let value = peak * (1 + wobble(at: Double(tick) * 0.25 + phase))
        return value.isFinite ? max(0, value) : peak
    }

    /// Zero-mean, deterministic, roughly ±10 %. Three incommensurate periods so the curve does
    /// not visibly repeat across 60 samples.
    private static func wobble(at t: Double) -> Double {
        0.052 * sin(t * 0.82)
            + 0.028 * sin(t * 2.13 + 0.7)
            + 0.017 * sin(t * 0.37 + 2.2)
    }

    // MARK: - Deterministic helpers

    /// Contiguous segments from `(size, permille, active)` triples starting at byte 0.
    ///
    /// `permille` rather than a `Double` percentage on purpose: `size * permille / 1000` is
    /// exact integer arithmetic, so a segment declared at 780 ‰ reports a `fraction` of exactly
    /// 0.78 rather than 0.7799999.
    static func makeSegments(_ spans: [(size: Int64, permille: Int64, active: Bool)]) -> [Download.Segment] {
        var segments: [Download.Segment] = []
        segments.reserveCapacity(spans.count)
        var lower: Int64 = 0
        for (index, span) in spans.enumerated() {
            guard span.size > 0 else { continue }
            let upper = lower + span.size - 1
            let received = span.size * span.permille / 1000
            segments.append(
                Download.Segment(
                    id: index,
                    range: lower...upper,
                    receivedBytes: received,
                    isActive: span.active
                )
            )
            lower = upper + 1
        }
        return segments
    }

    static func total(of segments: [Download.Segment]) -> Int64 {
        segments.reduce(Int64(0)) { $0 + $1.receivedBytes }
    }

    /// A fixed UUID per fixture. `UUID(uuid:)` from a literal byte pattern, so there is no
    /// force unwrap and no dependence on string parsing.

    /// All call sites pass a valid literal; the fallback exists only so this file contains no
    /// force unwrap. `CONVENTIONS.md` forbids `!` outside tests.
    private static func staticURL(_ string: String) -> URL {
        URL(string: string) ?? URL(filePath: "/dev/null")
    }

    /// FNV-1a. `Hasher` is seeded per process, so it cannot be used for anything that has to
    /// look the same in two different runs.
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func mimeType(forExtension ext: String) -> String? {
        switch ext {
        case "iso": "application/x-iso9660-image"
        case "dmg": "application/x-apple-diskimage"
        case "img": "application/octet-stream"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "m3u8": "application/vnd.apple.mpegurl"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "flac": "audio/flac"
        case "tar": "application/x-tar"
        case "zst", "zstd": "application/zstd"
        case "zip": "application/zip"
        case "gz", "tgz": "application/gzip"
        case "xz": "application/x-xz"
        case "bz2": "application/x-bzip2"
        case "7z": "application/x-7z-compressed"
        case "rar": "application/vnd.rar"
        case "pdf": "application/pdf"
        case "epub": "application/epub+zip"
        case "pkg": "application/vnd.apple.installer+xml"
        case "ipa": "application/octet-stream"
        case "deb": "application/vnd.debian.binary-package"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        default: nil
        }
    }
}


// MARK: - File-scope constants
//
// Swift forbids referencing a member of an actor from a default argument or a stored-property
// initialiser inside that same actor ("covariant 'Self'"). These two live at file scope so the
// fixtures can use them, and the actor re-exports them as computed statics for callers.

public let goelPreviewReferenceDate = Date(timeIntervalSince1970: 1_784_000_000)

/// A stable, human-recognisable UUID per fixture, so the same download keeps the same id
/// across launches and the deep-link / Live Activity paths can be exercised deterministically.
public func goelPreviewFixtureID(_ discriminator: UInt8) -> UUID {
        UUID(
            uuid: (
                0x60, 0xE1, 0x60, 0xE1,
                0x00, 0x00,
                0x40, 0x00,
                0x80, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, discriminator
            )
        )
}
