import ActivityKit
import Foundation

/// The Live Activity contract. Compiled into **both** the app and the widget extension —
/// the app publishes `ContentState`, the extension renders it.
///
/// Keep this file free of app-only types. It may import `ActivityKit` and `Foundation` only.
public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var filename: String
        public var receivedBytes: Int64
        public var totalBytes: Int64?
        public var fraction: Double
        public var speed: Double
        public var eta: TimeInterval?
        /// True when this activity stands for several downloads at once ("3 downloads · 62%").
        /// PRD §6.5: never one activity per download.
        public var isAggregate: Bool
        public var activeCount: Int
        public var isPaused: Bool
        /// When the app last produced these numbers. The stale branch renders "updated 2 min
        /// ago" from this instead of a percentage it cannot honestly claim.
        public var updatedAt: Date

        public init(
            filename: String,
            receivedBytes: Int64,
            totalBytes: Int64?,
            fraction: Double,
            speed: Double,
            eta: TimeInterval?,
            isAggregate: Bool,
            activeCount: Int,
            isPaused: Bool = false,
            updatedAt: Date
        ) {
            self.filename = filename
            self.receivedBytes = receivedBytes
            self.totalBytes = totalBytes
            self.fraction = Self.sanitize(fraction)
            self.speed = speed.isFinite && speed >= 0 ? speed : 0
            self.eta = (eta?.isFinite == true && (eta ?? 0) > 0) ? eta : nil
            self.isAggregate = isAggregate
            self.activeCount = activeCount
            self.isPaused = isPaused
            self.updatedAt = updatedAt
        }

        private static func sanitize(_ f: Double) -> Double {
            guard f.isFinite else { return 0 }
            return min(max(f, 0), 1)
        }

        /// "3 downloads" when aggregate, otherwise the filename.
        public var title: String {
            isAggregate ? "\(activeCount) downloads" : filename
        }
    }

    /// Stable across the activity's life — the download it stands for, or `"aggregate"`.
    public var downloadID: String
    /// `Download.Kind.token`, so the extension can pick a glyph without importing the model.
    public var kindToken: String

    public init(downloadID: String, kindToken: String) {
        self.downloadID = downloadID
        self.kindToken = kindToken
    }

    /// The single well-known ID used for the aggregate activity.
    public static let aggregateID = "aggregate"
}
