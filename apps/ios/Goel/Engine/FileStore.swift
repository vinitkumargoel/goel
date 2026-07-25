import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - FileStoreError

/// Everything that can go wrong between "I have a filename" and "there is a file descriptor".
///
/// Each case maps onto a ``TransferError`` so the engine never surfaces a raw `errno` to a user.
public enum FileStoreError: Error, Sendable, Equatable {
    /// The resolved path landed outside the app container. Always a bug or an attack; never
    /// something to recover from by "fixing up" the path.
    case escapesContainer(String)
    case cannotOpen(String)
    case cannotAllocate(String)
    case writeFailed(Int32)

    public var asTransferError: TransferError {
        switch self {
        case .escapesContainer:
            .invalidURL
        case let .cannotOpen(path):
            .network("Could not open \(path) for writing.")
        case .cannotAllocate:
            .diskFull
        case let .writeFailed(code):
            code == ENOSPC ? .diskFull : .network("Writing to disk failed (\(code)).")
        }
    }
}

// MARK: - SparseFile

/// A single open file that many concurrent segment writers share **safely**.
///
/// Six segments writing into one preallocated sparse file is the whole point of T05 — six temp
/// files plus a concatenation pass doubles peak disk and makes T10's play-while-downloading
/// impossible. The hazard that creates is a shared write cursor, and `FileHandle` has exactly
/// one of those: `seek(toOffset:)` then `write` is two operations, and two writers interleaving
/// them scatter each other's bytes across the file.
///
/// So this type never uses a cursor. Every write is a `pwrite(2)` — a *positioned* write that
/// takes its offset as an argument and does not touch the descriptor's file offset. POSIX
/// requires `pwrite` on a regular file to be atomic with respect to other writes, so N writers
/// on N non-overlapping ranges of one descriptor is correct by construction rather than by
/// convention.
///
/// It is a `final class` whose only stored properties are immutable and `Sendable`, which is
/// what makes the `Sendable` conformance real rather than `@unchecked`.
public final class SparseFile: Sendable {

    public let descriptor: Int32
    public let url: URL

    init(descriptor: Int32, url: URL) {
        self.descriptor = descriptor
        self.url = url
    }

    deinit {
        // The descriptor's lifetime is exactly this object's lifetime. There is no explicit
        // `close()` because an explicit close needs mutable "already closed" state, and mutable
        // state is the one thing this type is built to avoid.
        close(descriptor)
    }

    /// Writes `data` at an absolute file offset. Loops until the kernel has taken all of it —
    /// a short `pwrite` is legal and silently dropping the tail would corrupt the file.
    public func write(_ data: Data, at offset: Int64) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = pwrite(
                    descriptor,
                    base.advanced(by: written),
                    raw.count - written,
                    off_t(offset) + off_t(written)
                )
                if n > 0 {
                    written += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                throw FileStoreError.writeFailed(errno)
            }
        }
    }

    /// Pushes the page cache out to the device. Called at checkpoints and before the final
    /// rename, not per chunk — an `fsync` per 128 KB would halve throughput for no benefit.
    public func synchronize() {
        _ = fsync(descriptor)
    }
}

// MARK: - TransferCheckpoint

/// The per-segment cursor sidecar: what is already on disk, and which remote file it came from.
///
/// Written next to the `.part` file so a process kill mid-transfer resumes from the cursors
/// instead of restarting. `validator` is the guard — if the server's `ETag` no longer matches
/// what produced these bytes, the checkpoint is worthless and must be discarded rather than
/// spliced into a different file.
public struct TransferCheckpoint: Codable, Sendable, Equatable {

    /// One fully-written, inclusive byte range. Encoded as two integers rather than a
    /// `ClosedRange` so the JSON stays readable and stable if `ClosedRange`'s coding changes.
    public struct Span: Codable, Sendable, Equatable {
        public var lower: Int64
        public var upper: Int64
        public init(_ range: ClosedRange<Int64>) {
            self.lower = range.lowerBound
            self.upper = range.upperBound
        }
        public var range: ClosedRange<Int64> { lower...max(lower, upper) }
    }

    public static let currentVersion = 1

    public var version: Int
    public var url: String
    public var totalBytes: Int64?
    public var validator: String?
    public var supportsResume: Bool
    public var isSequential: Bool
    /// Merged, sorted, non-overlapping. Never contains a partially-written range.
    public var completed: [Span]

    public init(
        version: Int = TransferCheckpoint.currentVersion,
        url: String,
        totalBytes: Int64?,
        validator: String?,
        supportsResume: Bool,
        isSequential: Bool,
        completed: [ClosedRange<Int64>]
    ) {
        self.version = version
        self.url = url
        self.totalBytes = totalBytes
        self.validator = validator
        self.supportsResume = supportsResume
        self.isSequential = isSequential
        self.completed = completed.map(Span.init)
    }

    public var completedRanges: [ClosedRange<Int64>] { completed.map(\.range) }

    /// Bytes this checkpoint claims are already on disk.
    public var writtenBytes: Int64 {
        completed.reduce(0) { $0 + ($1.upper - $1.lower + 1) }
    }

    /// A checkpoint may only be adopted for the same URL *and* the same validator. A `nil`
    /// validator on either side means the server gave us nothing to prove sameness with, and
    /// unprovable sameness is exactly the case that silently corrupts a file.
    public func matches(url: URL, validator: String?) -> Bool {
        guard version == Self.currentVersion, self.url == url.absoluteString else { return false }
        guard let mine = self.validator, let theirs = validator else { return false }
        return mine == theirs
    }
}

// MARK: - BackgroundHandoffManifest

/// What a background `URLSession` task needs in order to splice its result into the right file
/// at the right offset — persisted, because the app may be *relaunched* to receive that result
/// and none of the in-memory state survives.
public struct BackgroundHandoffManifest: Codable, Sendable, Equatable {
    public var downloadID: UUID
    public var url: String
    public var partPath: String
    public var destinationPath: String
    /// The absolute file offset the background task's `Range:` header started at. The splice
    /// target. **Not** the download's current contiguous prefix, which moves.
    public var offset: Int64
    public var totalBytes: Int64?
    public var validator: String?
    public var startedAt: Date

    public init(
        downloadID: UUID,
        url: String,
        partPath: String,
        destinationPath: String,
        offset: Int64,
        totalBytes: Int64?,
        validator: String?,
        startedAt: Date = Date()
    ) {
        self.downloadID = downloadID
        self.url = url
        self.partPath = partPath
        self.destinationPath = destinationPath
        self.offset = offset
        self.totalBytes = totalBytes
        self.validator = validator
        self.startedAt = startedAt
    }
}

// MARK: - FileStore

/// **The one place in the app that turns a name into a path.**
///
/// The desktop build funnels every path through `PathSafety.isContained`; this is the iOS
/// equivalent, and the reason it is a separate type rather than three helpers on the engine is
/// that a sandbox escape is only auditable if there is a single function to audit.
///
/// Two decisions are load-bearing:
///
/// 1. **Downloads land in `Documents/`,** not Application Support and not `tmp`. `Info.plist`
///    sets `UIFileSharingEnabled`, which exposes exactly `Documents/` in Files.app — that is
///    T11's entire surface, and PRD §4.2's "make Files the feature". `tmp` is purged by the
///    system mid-transfer; Application Support is invisible to the user.
/// 2. **Containment is checked on the resolved path,** after `..` has been applied, because a
///    name like `../../Library/Preferences/x.plist` only looks dangerous once resolved.
public struct FileStore: Sendable {

    /// The container directory every download must land inside.
    public let root: URL

    /// Partial downloads carry an extension the system will not try to preview or index, and
    /// that makes an interrupted transfer obviously distinct from a finished file in Files.app.
    public static let partExtension = "goelpart"
    public static let checkpointExtension = "goelcursor"
    /// Hidden so it does not clutter the user's Files.app view of `Documents/`.
    public static let handoffDirectoryName = ".goel-handoff"

    public init(root: URL? = nil) {
        self.root = (root ?? FileStore.defaultRoot()).standardizedFileURL
    }

    /// `Documents/` — see the note above on why not Application Support.
    public static func defaultRoot() -> URL {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documents
        }
        // A device with no Documents directory is not a real configuration, but a crash here
        // would be a worse answer than a temporary directory that still works.
        return FileManager.default.temporaryDirectory
    }

    // MARK: - The choke point

    /// True when `candidate` resolves to a location strictly inside `root`.
    ///
    /// Compares path *components* rather than string prefixes: `/private/var/x/Documents2`
    /// has `/private/var/x/Documents` as a string prefix but is not inside it.
    public static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidateParts = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard candidateParts.count > rootParts.count else { return false }
        return Array(candidateParts.prefix(rootParts.count)) == rootParts
    }

    /// A filename that is safe to join onto `root`: percent-decoded, stripped of any directory
    /// part, stripped of control characters, and never `""`, `"."` or `".."`.
    public static func sanitizedFilename(_ raw: String) -> String {
        var value = raw.removingPercentEncoding ?? raw

        // Everything before the last separator is a path, and a path is not ours to honour.
        // Both separators, because a `Content-Disposition` from a Windows server may use `\`.
        if let separator = value.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            value = String(value[value.index(after: separator)...])
        }
        value = String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }))
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.isEmpty || value.allSatisfy({ $0 == "." }) { return "download" }

        // 255 bytes is the APFS component limit; leave room for the `.goelpart` suffix.
        if value.utf8.count > 200 {
            let ext = ProbeResult.fileExtension(of: value)
            let stem = String(value.prefix(160))
            value = ext.isEmpty ? stem : stem + "." + ext
        }
        return value
    }

    /// Where a finished file goes.
    ///
    /// `subdirectory` accepts what `Download.saveDirectory` actually contains in practice: a
    /// relative folder like `"Goel°/Linux"`, an absolute path inside the container (which is
    /// what `AppModel` writes back after a completion), or an absolute path outside it (a stale
    /// value from another install — ignored rather than honoured).
    public func destinationURL(filename: String, subdirectory: String? = nil) throws -> URL {
        var directory = root
        if let subdirectory, !subdirectory.isEmpty {
            let candidate = URL(filePath: subdirectory, directoryHint: .isDirectory)
            if subdirectory.hasPrefix("/") {
                directory = FileStore.isContained(candidate, in: root) ? candidate : root
            } else {
                for component in subdirectory.split(separator: "/") {
                    let safe = FileStore.sanitizedFilename(String(component))
                    guard safe != "download" || component == "download" else { continue }
                    directory = directory.appending(path: safe, directoryHint: .isDirectory)
                }
            }
        }

        let candidate = directory.appending(
            path: FileStore.sanitizedFilename(filename),
            directoryHint: .notDirectory
        )
        guard FileStore.isContained(candidate, in: root) else {
            throw FileStoreError.escapesContainer(candidate.path)
        }
        return candidate
    }

    // MARK: - Derived locations

    public func partURL(for destination: URL) -> URL {
        destination.appendingPathExtension(FileStore.partExtension)
    }

    public func checkpointURL(for destination: URL) -> URL {
        destination.appendingPathExtension(FileStore.checkpointExtension)
    }

    public func handoffManifestURL(for id: UUID) -> URL {
        root
            .appending(path: FileStore.handoffDirectoryName, directoryHint: .isDirectory)
            .appending(path: id.uuidString + ".json", directoryHint: .notDirectory)
    }

    // MARK: - Files

    /// Opens (creating if needed) the `.part` file and preallocates it sparsely to `size`.
    ///
    /// `ftruncate` to the final length costs no blocks on APFS — the file reads as `size` bytes
    /// of zeros and only materialises the extents that are actually written. That is what lets
    /// six segments seek to their own offsets on the first byte they receive.
    public func openPart(at url: URL, size: Int64?) throws -> SparseFile {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR | O_CREAT, 0o644)
        }
        guard descriptor >= 0 else { throw FileStoreError.cannotOpen(url.path) }
        let file = SparseFile(descriptor: descriptor, url: url)
        if let size, size > 0 {
            guard ftruncate(descriptor, off_t(size)) == 0 else {
                throw FileStoreError.cannotAllocate(url.path)
            }
        }
        return file
    }

    public func removePart(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves the finished `.part` onto its real name, never overwriting an existing file:
    /// `report.pdf` next to an existing `report.pdf` becomes `report (2).pdf`.
    public func finalize(part: URL, to destination: URL) throws -> URL {
        guard FileStore.isContained(destination, in: root) else {
            throw FileStoreError.escapesContainer(destination.path)
        }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let target = uniqueURL(for: destination)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: part, to: target)
        return target
    }

    func uniqueURL(for destination: URL) -> URL {
        guard FileManager.default.fileExists(atPath: destination.path) else { return destination }
        let directory = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        for counter in 2...999 {
            let name = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let candidate = directory.appending(path: name, directoryHint: .notDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return destination
    }

    // MARK: - Checkpoints

    public func saveCheckpoint(_ checkpoint: TransferCheckpoint, at url: URL) {
        do {
            let data = try Download.makeEncoder().encode(checkpoint)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // A checkpoint that cannot be written costs re-downloaded bytes on the next launch,
            // never a corrupt file — so it is logged and swallowed rather than failing a
            // transfer that is otherwise healthy. This is the only recoverable I/O failure here.
            NSLog("goel: checkpoint write failed at \(url.lastPathComponent): \(error)")
        }
    }

    public func loadCheckpoint(at url: URL) -> TransferCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Download.makeDecoder().decode(TransferCheckpoint.self, from: data)
    }

    public func removeCheckpoint(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Handoff manifests

    public func saveManifest(_ manifest: BackgroundHandoffManifest) {
        do {
            let data = try Download.makeEncoder().encode(manifest)
            let url = handoffManifestURL(for: manifest.downloadID)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("goel: handoff manifest write failed for \(manifest.downloadID): \(error)")
        }
    }

    public func loadManifest(for id: UUID) -> BackgroundHandoffManifest? {
        guard let data = try? Data(contentsOf: handoffManifestURL(for: id)) else { return nil }
        return try? Download.makeDecoder().decode(BackgroundHandoffManifest.self, from: data)
    }

    public func removeManifest(for id: UUID) {
        try? FileManager.default.removeItem(at: handoffManifestURL(for: id))
    }

    // MARK: - Hashing

    /// SHA-256 of a file, read in 1 MB chunks.
    ///
    /// Streamed on purpose: `Data(contentsOf:)` on a 200 MB download is 200 MB of resident
    /// memory and a jetsam kill on a phone, and the files this app exists for are larger still.
    public static func sha256Hex(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Pulls the 64-hex-character digest out of a `shasum`-style sidecar, which may be a bare
    /// digest or `"<digest>  <filename>"`. Returns `nil` for anything that is not a digest —
    /// an HTML 404 page must never be mistaken for a checksum.
    public static func parseChecksumSidecar(_ text: String) -> String? {
        for field in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            let candidate = field.lowercased()
            guard candidate.count == 64 else { continue }
            guard candidate.allSatisfy(\.isHexDigit) else { continue }
            return candidate
        }
        return nil
    }
}
