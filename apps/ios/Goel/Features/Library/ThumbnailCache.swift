import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import OSLog
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// Disk-backed thumbnail cache for the Library's Media grid.
///
/// Generating a thumbnail is expensive — `AVAssetImageGenerator` decodes a frame, QuickLook
/// spins up an out-of-process renderer — and a `LazyVGrid` will ask for the same tile every
/// time it crosses the viewport edge. Regenerating on every scroll makes the grid crawl, so
/// results are memoised twice: a small in-memory LRU for the current scroll session, and a
/// JPEG on disk that survives relaunch.
///
/// Three properties are load-bearing:
///
/// 1. **The key is content-addressed** — file path *plus* modification date *plus* byte size
///    *plus* the requested pixel size. A file replaced in place by a re-download keeps its
///    path, so path alone would serve a stale frame forever.
/// 2. **The cache lives in `Caches/`, never in `Documents/`.** `Documents/` is the user-visible
///    Files-app container (PRD §4.2); littering it with `.jpg` sidecars would put generated
///    junk in front of the user and inflate their iCloud backup.
/// 3. **Identical concurrent requests are coalesced.** Two tiles that appear in the same frame
///    for the same URL share one generation task rather than decoding the asset twice.
///
/// This is an `actor`, so every generation runs off the main actor by construction. Views must
/// never call `UIImage` generation inline.
public actor ThumbnailCache {

    /// The app-wide instance. One cache means one in-flight table, which is the whole point.
    public static let shared = ThumbnailCache()

    // MARK: - Tunables

    /// In-memory entries kept before the least-recently-used one is dropped. Sized for a couple
    /// of screens of grid, not for the whole library — the disk tier catches the rest.
    private static let memoryLimit = 120

    /// Files kept on disk before the oldest are pruned. A thumbnail is a few KB; this bounds
    /// the cache at a handful of megabytes.
    private static let diskLimit = 600

    /// Writes between prune sweeps. Statting the whole directory on every write would undo the
    /// point of caching.
    private static let pruneInterval = 64

    /// JPEG is right here: thumbnails are photographic, and a PNG of a decoded video frame is
    /// several times larger for no visible gain.
    private static let compressionQuality: CGFloat = 0.8

    // MARK: - State

    private let directory: URL
    private let fileManager: FileManager

    private var memory: [String: UIImage] = [:]
    /// Least-recently-used first. Small enough that array churn is cheaper than a linked list.
    private var recency: [String] = []
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var writesSincePrune = 0
    private var directoryReady = false

    private let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "ThumbnailCache")

    // MARK: - Life cycle

    /// - Parameter directory: overridable so tests can point at a scratch location instead of
    ///   the real caches container.
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? URL.cachesDirectory
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    // MARK: - Public API

    /// A thumbnail for `url` at `size` points, or `nil` when the file cannot be rendered.
    ///
    /// Returns from memory, then disk, then generates. Never throws: a missing thumbnail is a
    /// placeholder tile, not an error the user should read about.
    public func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        guard let key = cacheKey(for: url, size: size, scale: scale) else { return nil }

        if let hit = memory[key] {
            touch(key)
            return hit
        }

        if let onDisk = readFromDisk(key) {
            store(onDisk, for: key)
            return onDisk
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [directory = self.directory] in
            _ = directory  // capture keeps the actor out of the detached body's closure
            return await Self.generate(url: url, size: size, scale: scale)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            store(image, for: key)
            writeToDisk(image, key: key)
        }
        return image
    }

    /// Drops every memoised thumbnail, in memory and on disk. Wired to Settings' "clear cache".
    public func clear() {
        memory.removeAll()
        recency.removeAll()
        try? fileManager.removeItem(at: directory)
        directoryReady = false
        writesSincePrune = 0
    }

    /// Whether a rendered thumbnail already exists for this file, without generating one.
    /// Lets a caller decide between a real tile and a symbol placeholder without paying for a
    /// decode it may immediately scroll past.
    public func isCached(_ url: URL, size: CGSize, scale: CGFloat) -> Bool {
        guard let key = cacheKey(for: url, size: size, scale: scale) else { return false }
        if memory[key] != nil { return true }
        return fileManager.fileExists(atPath: fileURL(for: key).path(percentEncoded: false))
    }

    // MARK: - Keying

    /// Path + modification date + byte size + requested pixel size, hashed to a stable
    /// filename. Dropping any one of these serves a wrong image at some point: drop the date
    /// and a re-download shows the old frame; drop the size and a grid tile gets a list-sized
    /// image scaled up to mush.
    private func cacheKey(for url: URL, size: CGSize, scale: CGFloat) -> String? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let bytes = values?.fileSize ?? 0
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        let seed = """
        \(url.standardizedFileURL.path(percentEncoded: false))\
        |\(Int64(modified.rounded()))\
        |\(bytes)\
        |\(Int(pixels.width.rounded()))x\(Int(pixels.height.rounded()))
        """
        guard let data = seed.data(using: .utf8) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for key: String) -> URL {
        directory.appending(path: "\(key).jpg", directoryHint: .notDirectory)
    }

    // MARK: - Memory tier

    private func store(_ image: UIImage, for key: String) {
        memory[key] = image
        touch(key)
        while recency.count > Self.memoryLimit, let oldest = recency.first {
            recency.removeFirst()
            memory[oldest] = nil
        }
    }

    private func touch(_ key: String) {
        if let existing = recency.firstIndex(of: key) { recency.remove(at: existing) }
        recency.append(key)
    }

    // MARK: - Disk tier

    private func readFromDisk(_ key: String) -> UIImage? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return UIImage(data: data)
    }

    private func writeToDisk(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: Self.compressionQuality) else { return }
        ensureDirectory()
        do {
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            // A cache that cannot write is slow, not broken. Never surface this.
            log.debug("Thumbnail write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        writesSincePrune += 1
        if writesSincePrune >= Self.pruneInterval {
            writesSincePrune = 0
            prune()
        }
    }

    private func ensureDirectory() {
        guard !directoryReady else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryReady = true
    }

    /// Oldest-accessed files go first. `contentsOfDirectory` here is the reason this runs once
    /// every ``pruneInterval`` writes rather than on each one.
    private func prune() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), contents.count > Self.diskLimit else { return }

        let dated = contents.map { url -> (url: URL, date: Date) in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.date < $1.date }

        for entry in dated.prefix(dated.count - Self.diskLimit) {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    // MARK: - Generation

    /// Video goes through `AVAssetImageGenerator`; everything else through QuickLook.
    ///
    /// `nonisolated` and `static` on purpose — generation touches no actor state, so it must not
    /// hold the actor's executor while an asset decodes.
    private nonisolated static func generate(url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        if isAudiovisual(url), let frame = await videoFrame(url: url, size: size, scale: scale) {
            return frame
        }
        return await quickLookThumbnail(url: url, size: size, scale: scale)
    }

    /// A frame from roughly a tenth of the way in — frame zero of a video is very often a black
    /// or letterboxed leader, which renders as an empty tile.
    private nonisolated static func videoFrame(url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * scale, height: size.height * scale)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let seconds: Double
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite {
            seconds = min(max(duration.seconds * 0.1, 0), max(duration.seconds - 0.1, 0))
        } else {
            seconds = 0
        }

        guard let cgImage = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// QuickLook covers images, PDFs, and anything else the system knows how to draw — and
    /// falls back to the document icon rather than failing, which is a fine tile.
    private nonisolated static func quickLookThumbnail(url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.uiImage)
            }
        }
    }

    /// Extension-based, not UTType-based, because the file may not exist on disk yet when the
    /// grid asks and `UTType(filenameExtension:)` is the cheap, allocation-free check.
    private nonisolated static func isAudiovisual(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .movie)
    }
}
