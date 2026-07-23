import Foundation

// MARK: - ProbeResult

/// What the engine learned about a remote file *before* the user commits to downloading it.
///
/// `docs/PRD-iOS.md` calls this out as a defining behaviour: name, exact size, type and
/// resumability are known before the tap, so there are no surprises at 99 %. The add sheet in
/// `visual.html` renders exactly these five fields.
///
/// Deliberately free of every URLSession type. This struct crosses the seam that `GoelCore`
/// will implement later via `GoelFacade`; the moment it carries a `URLResponse` the seam leaks.
public struct ProbeResult: Sendable, Equatable {

    /// The filename to save as — from `Content-Disposition` if the server sent one, else the
    /// last path component of the URL.
    public var filename: String

    /// `nil` when the server refused to report a length (chunked transfer, no `Content-Length`).
    /// Everything downstream must cope with an unknown size rather than guessing one.
    public var totalBytes: Int64?

    /// The server sent `Accept-Ranges: bytes`. Without this there is no resume and no
    /// segmentation — one connection, from zero, every time.
    public var supportsResume: Bool

    /// The declared MIME type, lowercased, without parameters. `nil` when absent.
    public var mimeType: String?

    /// Video that can be played while it downloads: a video container *and* seekable.
    /// Drives T10's "playable now" affordance.
    public var isStreamable: Bool

    /// `ETag` when the server sent one, otherwise `Last-Modified`. Replayed as `If-Range` on
    /// resume so a file that changed on the server produces a fresh `200` rather than a
    /// silently corrupt splice.
    public var validator: String?

    public init(
        filename: String,
        totalBytes: Int64?,
        supportsResume: Bool,
        mimeType: String?,
        isStreamable: Bool,
        validator: String?
    ) {
        self.filename = filename
        self.totalBytes = totalBytes
        self.supportsResume = supportsResume
        self.mimeType = mimeType
        self.isStreamable = isStreamable
        self.validator = validator
    }

    /// The one-line "Type" row in the add sheet: `"Disk Image · resumable"`,
    /// `"Video · streamable"`, `"Archive"`, `"Unknown"`.
    ///
    /// Streamability outranks resumability in the suffix because it is the stronger promise —
    /// anything streamable is necessarily seekable, and therefore resumable too.
    public var typeDescription: String {
        let base = Self.category(mimeType: mimeType, filename: filename)
        if isStreamable { return base + " · streamable" }
        if supportsResume { return base + " · resumable" }
        return base
    }

    /// The lowercased final path extension of a filename, or `""`. Handles `foo.tar.zst` by
    /// returning `zst` — the compound extension is not a separate category.
    static func fileExtension(of filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return "" }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }

    static func category(mimeType: String?, filename: String) -> String {
        // A declared MIME type beats the extension: the server knows what it is serving.
        let mime = (mimeType ?? "").lowercased()
        if mime.hasPrefix("video/") || mime == "application/vnd.apple.mpegurl" { return "Video" }
        if mime.hasPrefix("audio/") { return "Audio" }
        if mime.hasPrefix("image/") { return "Image" }
        if mime == "application/x-apple-diskimage" || mime == "application/x-iso9660-image" {
            return "Disk Image"
        }
        if mime == "application/pdf" || mime == "application/epub+zip" { return "Document" }

        switch Self.fileExtension(of: filename) {
        case "iso", "dmg", "img", "vhd", "vhdx", "vmdk", "qcow2":
            return "Disk Image"
        case "mp4", "m4v", "mov", "mkv", "webm", "avi", "m3u8", "m3u":
            return "Video"
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus":
            return "Audio"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "zstd", "7z", "rar", "lz4":
            return "Archive"
        case "pdf", "epub", "docx", "pages", "txt", "csv", "json":
            return "Document"
        case "pkg", "ipa", "apk", "deb", "rpm", "exe", "msi", "appimage":
            return "Installer"
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff":
            return "Image"
        default:
            return "Unknown"
        }
    }
}

// MARK: - TransferEvent

/// Everything an engine tells the rest of the app, on one stream.
///
/// Value types only. Nothing here may reference a `URLSessionTask`, a `URLResponse`, or any
/// other URLSession type — see the note on ``TransferEngine``.
public enum TransferEvent: Sendable {

    /// Bytes moved. `total` is `nil` when the server never reported a length.
    /// `speed` is bytes per second over the engine's sampling window, never `NaN`.
    case progress(id: UUID, received: Int64, total: Int64?, speed: Double, segments: [Download.Segment])

    /// A state transition the UI must reflect — including the ones the user did not ask for,
    /// like dropping to `.waitingForWiFi`.
    case statusChanged(id: UUID, status: Download.Status)

    /// The file is fully written and verified. `fileURL` is where it landed on disk.
    case completed(id: UUID, fileURL: URL)

    /// Terminal failure. `message` is already user-facing — see ``TransferError/userMessage``.
    case failed(id: UUID, message: String)

    /// The download every event belongs to. Lets a subscriber route by id without a full
    /// `switch` at each call site.
    public var downloadID: UUID {
        switch self {
        case let .progress(id, _, _, _, _): id
        case let .statusChanged(id, _): id
        case let .completed(id, _): id
        case let .failed(id, _): id
        }
    }
}

// MARK: - TransferError

/// The failure vocabulary of the seam. Closed on purpose: every case has a written,
/// user-facing sentence, so no engine can surface a raw `NSError` description to a person.
public enum TransferError: Error, Sendable, Equatable {
    case invalidURL
    case unsupportedScheme(String)
    /// The `If-Range` validator no longer matches, or the server answered `416`. The bytes on
    /// disk belong to a different file than the one now being served.
    case remoteFileChanged
    case notFound
    case network(String)
    case cancelled
    case diskFull
    case checksumMismatch

    /// A complete sentence, safe to put in front of a user. No error codes, no jargon.
    public var userMessage: String {
        switch self {
        case .invalidURL:
            "That does not look like a valid link."
        case let .unsupportedScheme(scheme):
            "Downloads over \(scheme) are not supported yet."
        case .remoteFileChanged:
            "The file changed on the server, so the part already downloaded can no longer be used. Start it again to get the new version."
        case .notFound:
            "The server could not find that file."
        case let .network(detail):
            detail.isEmpty ? "The connection failed." : "The connection failed: \(detail)"
        case .cancelled:
            "Download cancelled."
        case .diskFull:
            "There is not enough space left on this iPhone to finish this download."
        case .checksumMismatch:
            "The finished file did not match its checksum, so it was not kept."
        }
    }
}

// MARK: - TransferEngine

/// The seam. Everything above this line is the app; everything below it is one interchangeable
/// transfer implementation.
///
/// Three implementations are planned and only the first two exist tonight:
/// `PreviewTransferEngine` (deterministic, no I/O), `URLSessionTransferEngine` (T05/T06), and
/// eventually `GoelCore` behind a `GoelFacade`. Keeping this protocol free of URLSession types
/// is what makes the third one possible — if you find yourself wanting to expose a
/// `URLSessionTask` here, the implementation is leaking through the seam.
///
/// ## Threading
///
/// Conformers are actors, so every method is `async` from the outside. Only ``start(_:)`` and
/// ``probe(_:)`` throw: a pause that fails is not a thing a user can act on, and a pause that
/// silently no-ops is a bug — implementations must apply the mutation or emit a
/// ``TransferEvent/statusChanged(id:status:)`` explaining why they did not.
public protocol TransferEngine: Actor {

    /// Begins (or restarts) a transfer. Throws ``TransferError`` before any bytes move.
    func start(_ download: Download) async throws

    /// Suspends a transfer, keeping the bytes already on disk. A no-op for an unknown id.
    func pause(_ id: UUID) async

    /// Continues a paused transfer from its existing byte ranges.
    func resume(_ id: UUID) async

    /// Stops a transfer for good. `deleteData: true` discards the partial file as well.
    func cancel(_ id: UUID, deleteData: Bool) async

    /// Resolves a URL's metadata without downloading its body.
    func probe(_ url: URL) async throws -> ProbeResult

    /// **One** stream for all downloads, not one per download. Views subscribe once, at app
    /// launch, and route by ``TransferEvent/downloadID``.
    ///
    /// `nonisolated` so a `@MainActor` view can take the stream without an `await` and without
    /// a suspension point in `body`.
    ///
    /// - Important: The contract is **one subscriber** — the app's event pump. `AsyncStream`
    ///   delivers each element to exactly one consumer, so a second `for await` loop over the
    ///   same stream steals events from the first rather than mirroring them. If a second
    ///   consumer is ever needed, fan out from the pump, do not iterate this twice.
    nonisolated var events: AsyncStream<TransferEvent> { get }
}
