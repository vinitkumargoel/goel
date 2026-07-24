import AVFoundation
import Foundation
import OSLog
import UniformTypeIdentifiers

// MARK: - PartialFileWindow

/// The range arithmetic that makes play-while-downloading work, as a pure value type.
///
/// T05's sequential mode guarantees bytes `0…contiguousPrefix` are on disk with no holes, so the
/// `.goelpart` file is a valid *prefix* of a valid file. The `.part` file is also preallocated to
/// its final length with `ftruncate` (see ``FileStore/openPart(at:size:)``), which means reading
/// past the write head returns **zeros, not EOF**. Nothing in the file itself says where the real
/// bytes stop. That watermark lives here, and every read is gated on it.
///
/// Testable without AVFoundation, a simulator, or a file — which is the point of splitting it out.
struct PartialFileWindow: Sendable, Equatable {

    /// One byte past the last contiguous byte on disk. `Download.contiguousPrefix`.
    var writeHead: Int64
    /// The file's eventual length, from the server. `nil` until the probe lands.
    var totalBytes: Int64?

    /// What can be done about a requested byte range *right now*.
    enum Fulfilment: Sendable, Equatable {
        /// Every requested byte is already on disk. Serve it and finish.
        case ready(offset: Int64, length: Int)
        /// The range straddles the write head. Serve the front of it and keep the request open.
        case partial(offset: Int64, length: Int)
        /// The range starts at or past the write head. **Pend** — do not fail. Failing here is
        /// what makes `AVPlayer` treat the write head as end-of-stream and stop the movie at 23 %.
        case pending
        /// Nothing left to serve: the range starts at or past the end of a file of known length,
        /// or has zero length. Finish the request cleanly.
        case exhausted
    }

    init(writeHead: Int64 = 0, totalBytes: Int64? = nil) {
        self.writeHead = max(0, writeHead)
        self.totalBytes = totalBytes
    }

    func fulfilment(offset: Int64, length: Int) -> Fulfilment {
        let head = max(0, writeHead)
        let start = max(0, offset)

        if let totalBytes, totalBytes > 0, start >= totalBytes { return .exhausted }

        var wanted = Int64(max(0, length))
        if let totalBytes, totalBytes > 0 { wanted = min(wanted, totalBytes - start) }
        guard wanted > 0 else { return .exhausted }

        let available = head - start
        guard available > 0 else { return .pending }
        if available >= wanted { return .ready(offset: start, length: Int(wanted)) }
        return .partial(offset: start, length: Int(available))
    }
}

// MARK: - MP4Layout

/// Where an MP4's index sits relative to its media data.
enum MP4Layout: Sendable, Equatable {
    /// `moov` precedes `mdat` — the file describes itself before it presents itself, so a prefix
    /// of it is playable. This is what `ffmpeg -movflags +faststart` produces.
    case fastStart
    /// `mdat` precedes `moov`. The index is at the *end*, so nothing is playable until the last
    /// byte lands. That is a property of the file, not a bug in the player, and the UI says so.
    case moovAtEnd
    /// Not enough bytes yet, or not an ISO base-media file at all (MKV, TS, …). Let AVFoundation
    /// decide rather than guessing.
    case undetermined
}

/// ISO base-media (MP4/MOV) top-level box walking — just enough to answer one question.
enum MediaContainer {

    /// Walks the top-level box list looking for whichever of `moov` / `mdat` comes first.
    ///
    /// - Parameters:
    ///   - prefix: the head of the file. A few hundred kilobytes is plenty: `ftyp` is ~32 bytes
    ///     and a faststart `moov` follows immediately.
    ///   - fileLength: the eventual total length, used only to size a `size == 0` ("to EOF") box.
    static func inspect(_ prefix: Data, fileLength: Int64? = nil) -> MP4Layout {
        let bytes = [UInt8](prefix)
        guard bytes.count >= 8 else { return .undetermined }

        var cursor = 0
        var boxes = 0
        // A well-formed file reaches moov or mdat within a handful of top-level boxes. The cap is
        // there so a corrupt length field cannot spin this loop.
        while cursor + 8 <= bytes.count, boxes < maxTopLevelBoxes {
            var size = Int64(be32(bytes, at: cursor))
            let type = String(decoding: bytes[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            var header: Int64 = 8

            if size == 1 {
                // 64-bit `largesize` immediately after the type.
                guard cursor + 16 <= bytes.count else { return .undetermined }
                size = Int64(bitPattern: be64(bytes, at: cursor + 8))
                header = 16
            } else if size == 0 {
                // "Extends to end of file" — legal for the last box.
                size = (fileLength ?? Int64(bytes.count)) - Int64(cursor)
            }

            switch type {
            case "moov": return .fastStart
            case "mdat": return .moovAtEnd
            default: break
            }

            guard size >= header,
                  let next = Int(exactly: Int64(cursor) + size),
                  next > cursor
            else { return .undetermined }
            cursor = next
            boxes += 1
        }
        return .undetermined
    }

    /// How much of the file's head is worth reading to answer ``inspect(_:fileLength:)``.
    static let probeBytes = 256 * 1024

    private static let maxTopLevelBoxes = 64

    private static func be32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }

    private static func be64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 { value = (value << 8) | UInt64(bytes[index + offset]) }
        return value
    }

    /// The UTI `AVAssetResourceLoadingContentInformationRequest.contentType` wants, inferred from
    /// the filename. Falls back to MP4, which is what the app's own fixture and the overwhelming
    /// majority of progressive-download video is.
    static func contentType(forFilename filename: String) -> String {
        let ext = URL(filePath: filename).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .audiovisualContent) else {
            return UTType.mpeg4Movie.identifier
        }
        return type.identifier
    }
}

// MARK: - PartialFileResourceLoader

/// Serves byte ranges out of a still-downloading file to `AVPlayer`, and **pends** the ones that
/// have not arrived yet.
///
/// Handing `AVPlayer` a `file://` URL for a `.goelpart` does not work: AVFoundation reads the
/// length once, sees the preallocated size, gets zeros past the write head, and either fails to
/// parse or plays silence. Handing it a custom scheme routes every read through this object, which
/// knows two things the file does not — where the real bytes stop, and that more are coming.
///
/// Three answers to `contentInformationRequest` are load-bearing:
/// * `contentLength` is the **expected total**, not what is on disk. Report the write head and
///   AVFoundation plans for a file that ends at 23 %.
/// * `isByteRangeAccessSupported = true`, or it will not seek at all.
/// * `contentType` as a UTI, or it will not pick a demuxer.
///
/// ### Concurrency
/// Every stored property is touched only on ``deliveryQueue``, which is also the queue passed to
/// `AVAssetResourceLoader.setDelegate(_:queue:)`. That is what makes the `@unchecked Sendable`
/// honest, and it keeps file reads off the main thread. ``advance(writeHead:totalBytes:)`` is the
/// one entry point from the outside and it hops onto that queue itself.
final class PartialFileResourceLoader: NSObject, @unchecked Sendable {

    /// The scheme that routes `AVURLAsset` through this delegate instead of the file system.
    static let scheme = "goel-partial"

    /// The queue every delegate callback and every mutation happens on.
    let deliveryQueue = DispatchQueue(label: "\(GoelIdentifiers.logSubsystem).partial-loader")

    private let fileURL: URL
    private let contentType: String
    private let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "player")

    // MARK: State — deliveryQueue only

    private var window: PartialFileWindow
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var handle: FileHandle?
    private var isPumpScheduled = false

    init(fileURL: URL, contentType: String, window: PartialFileWindow) {
        self.fileURL = fileURL
        self.contentType = contentType
        self.window = window
        super.init()
    }

    deinit {
        try? handle?.close()
    }

    /// The URL to hand `AVURLAsset`. The path carries the real filename only so logs and error
    /// messages read sensibly; the content type comes from ``contentType``, not the extension.
    static func playbackURL(for id: UUID, filename: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = id.uuidString.lowercased()
        components.path = "/" + FileStore.sanitizedFilename(filename)
        return components.url
    }

    /// More bytes landed. Widens the window and releases whatever was waiting on them.
    func advance(writeHead: Int64, totalBytes: Int64?) {
        deliveryQueue.async { [self] in
            window.writeHead = max(window.writeHead, max(0, writeHead))
            if let totalBytes, totalBytes > 0 { window.totalBytes = totalBytes }
            pump()
        }
    }

    /// Finishes every outstanding request and closes the descriptor. Called when the view goes
    /// away — a pending request that is never answered keeps `AVPlayer` alive forever.
    func invalidate() {
        deliveryQueue.async { [self] in
            for request in pending where !request.isFinished { request.finishLoading() }
            pending.removeAll()
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: - Serving

    private func pump() {
        guard !pending.isEmpty else { return }
        pending.removeAll { request in
            if request.isCancelled || request.isFinished { return true }
            return serve(request)
        }
    }

    /// - Returns: `true` when the request is finished and can be dropped from ``pending``.
    private func serve(_ request: AVAssetResourceLoadingRequest) -> Bool {
        if let information = request.contentInformationRequest { fill(information) }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        // `requestsAllDataToEndOfResource` means "everything from here on", which is only bounded by
        // the file's eventual length. Until the probe reports one, the write head is the bound.
        let end: Int64 = dataRequest.requestsAllDataToEndOfResource
            ? (window.totalBytes ?? window.writeHead)
            : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)

        var served = 0
        while served < Self.maxBytesPerPump {
            let start = max(dataRequest.currentOffset, dataRequest.requestedOffset)
            let remaining = end - start
            guard remaining > 0 else {
                request.finishLoading()
                return true
            }
            let chunk = Int(min(remaining, Int64(Self.maxChunkBytes)))

            switch window.fulfilment(offset: start, length: chunk) {
            case .exhausted:
                request.finishLoading()
                return true

            case .pending:
                // The bytes are not there yet. Hold the request open — this is the whole trick.
                return false

            case let .ready(offset, length), let .partial(offset, length):
                guard let data = read(offset: offset, length: length), !data.isEmpty else {
                    log.error("Partial read failed at \(offset, privacy: .public)")
                    request.finishLoading(with: URLError(.cannotOpenFile))
                    return true
                }
                dataRequest.respond(with: data)
                served += data.count
            }
        }

        // Yielded on the byte budget rather than on availability: come back for the rest.
        scheduleFollowUpPump()
        return false
    }

    private func fill(_ information: AVAssetResourceLoadingContentInformationRequest) {
        information.contentType = contentType
        information.isByteRangeAccessSupported = true
        // The *expected total*, not what is on disk. Reporting the write head here is what makes
        // AVFoundation stop the movie at the download's current percentage.
        information.contentLength = window.totalBytes ?? 0
    }

    private func read(offset: Int64, length: Int) -> Data? {
        if handle == nil { handle = try? FileHandle(forReadingFrom: fileURL) }
        guard let handle else { return nil }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    private func scheduleFollowUpPump() {
        guard !isPumpScheduled else { return }
        isPumpScheduled = true
        deliveryQueue.asyncAfter(deadline: .now() + Self.followUpDelay) { [self] in
            isPumpScheduled = false
            pump()
        }
    }

    /// Cap on a single `respond(with:)`. Bounds peak memory on a multi-gigabyte file.
    private static let maxChunkBytes = 256 * 1024
    /// Cap on the work one `pump()` does for one request before yielding the queue, so a request
    /// for an already-complete 5 GB prefix cannot monopolise the loader.
    private static let maxBytesPerPump = 4 * 1024 * 1024
    private static let followUpDelay: TimeInterval = 0.005
}

// MARK: - AVAssetResourceLoaderDelegate

extension PartialFileResourceLoader: AVAssetResourceLoaderDelegate {

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // `true` means "I will finish this myself, eventually" — including "not until more of the
        // download arrives". Returning `false` would tell AVFoundation the resource is unavailable.
        if serve(loadingRequest) { return true }
        pending.append(loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pending.removeAll { $0 === loadingRequest }
    }
}
