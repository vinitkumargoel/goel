import Foundation
import TorrentBridge

/// Builds a .torrent from a local file or folder (libtorrent's `create_torrent`).
public enum TorrentCreator {

    public struct Options: Sendable, Equatable {
        public var sourcePath: String
        public var outputPath: String
        public var trackers: [String]
        public var webSeeds: [String]
        /// Bytes; 0 lets libtorrent pick from the payload size.
        public var pieceSize: Int
        public var isPrivate: Bool
        public var comment: String

        public init(sourcePath: String, outputPath: String, trackers: [String] = [],
                    webSeeds: [String] = [], pieceSize: Int = 0, isPrivate: Bool = false,
                    comment: String = "") {
            self.sourcePath = sourcePath
            self.outputPath = outputPath
            self.trackers = trackers
            self.webSeeds = webSeeds
            self.pieceSize = pieceSize
            self.isPrivate = isPrivate
            self.comment = comment
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return L10n.t("Torrent creation was cancelled.")
            case .failed(let message): return message
            }
        }
    }

    /// Piece sizes offered in the UI (bytes); 0 = automatic.
    public static let pieceSizes: [Int] = [0] + (14...24).map { 1 << $0 }

    /// Hashes on a dedicated thread. `progress` gets 0…1 and returns false to cancel.
    public static func create(_ options: Options,
                              progress: @escaping @Sendable (Double) -> Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let thread = Thread {
                continuation.resume(with: run(options, progress: progress))
            }
            thread.name = "goel.torrent-create"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private final class ProgressBox {
        let report: @Sendable (Double) -> Bool
        init(_ report: @escaping @Sendable (Double) -> Bool) { self.report = report }
    }

    private static func run(_ o: Options,
                            progress: @escaping @Sendable (Double) -> Bool) -> Result<URL, Error> {
        let box = ProgressBox(progress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }
        let callback: GTCreateProgress = { raw, done, total in
            guard let raw else { return 0 }
            let box = Unmanaged<ProgressBox>.fromOpaque(raw).takeUnretainedValue()
            let fraction = total > 0 ? Double(done) / Double(total) : 0
            return box.report(fraction) ? 0 : 1
        }
        var err = [CChar](repeating: 0, count: 512)
        let trackers = o.trackers.map { strdup($0) }
        let seeds = o.webSeeds.map { strdup($0) }
        defer { (trackers + seeds).forEach { free($0) } }
        var trackerPtrs: [UnsafePointer<CChar>?] = trackers.map { $0.map { UnsafePointer($0) } }
        var seedPtrs: [UnsafePointer<CChar>?] = seeds.map { $0.map { UnsafePointer($0) } }
        let trackerCount = Int32(trackerPtrs.count)
        let seedCount = Int32(seedPtrs.count)
        let result: Int32 = trackerPtrs.withUnsafeMutableBufferPointer { tp in
            seedPtrs.withUnsafeMutableBufferPointer { sp in
                err.withUnsafeMutableBufferPointer { eb in
                    gt_create_torrent(o.sourcePath,
                                      trackerCount > 0 ? tp.baseAddress : nil, trackerCount,
                                      seedCount > 0 ? sp.baseAddress : nil, seedCount,
                                      Int32(clamping: o.pieceSize), o.isPrivate ? 1 : 0, o.comment,
                                      o.outputPath, callback, ctx, eb.baseAddress, 512)
                }
            }
        }
        switch result {
        case 1: return .success(URL(fileURLWithPath: o.outputPath))
        case -1: return .failure(Failure.cancelled)
        default:
            let message = String(cString: err)
            return .failure(Failure.failed(message.isEmpty ? L10n.t("Could not create the torrent.") : message))
        }
    }

    /// "<name>.torrent" beside the source.
    public static func defaultOutputPath(for sourcePath: String) -> String {
        let url = URL(fileURLWithPath: sourcePath)
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".torrent").path
    }
}
