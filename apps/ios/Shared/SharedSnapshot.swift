import Foundation
import os

/// The narrow slice of app state the widget extension is allowed to see.
///
/// Compiled into **both** targets, so it may import nothing beyond `Foundation` and `os`, and
/// it must not mention `Download` — that type lives only in the app. The widget process gets a
/// few dozen bytes of JSON out of the App Group container and nothing else. Widget memory
/// budgets are small enough that decoding the full queue would be a real risk.
public struct SharedSnapshot: Codable, Sendable, Equatable {

    /// One row a widget can draw. Everything is pre-formatted-adjacent: raw numbers the widget
    /// renders with its own formatters, plus a plain `kindToken` string so this file need not
    /// know the app's `Download.Kind` enum.
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var filename: String
        public var fraction: Double
        public var speed: Double
        public var kindToken: String
        public var isPaused: Bool

        public init(id: String, filename: String, fraction: Double, speed: Double, kindToken: String, isPaused: Bool) {
            self.id = id
            self.filename = filename
            self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            self.speed = speed.isFinite && speed > 0 ? speed : 0
            self.kindToken = kindToken
            self.isPaused = isPaused
        }
    }

    public var activeCount: Int
    public var totalRemainingBytes: Int64
    /// Throughput across the **entire** live queue, not just ``top``. The widget's ETA divides
    /// ``totalRemainingBytes`` (full queue) by this, so summing only the top-3 rows' speeds would
    /// systematically inflate the estimate whenever more than three downloads run at once.
    public var totalSpeed: Double
    public var aggregateFraction: Double
    public var updatedAt: Date
    /// At most three. The initializer truncates, so no caller can hand a widget ten rows.
    public var top: [Item]

    /// How many rows a snapshot may carry.
    public static let topLimit = 3

    public init(activeCount: Int, totalRemainingBytes: Int64, totalSpeed: Double = 0, aggregateFraction: Double, updatedAt: Date, top: [Item]) {
        self.activeCount = activeCount
        self.totalRemainingBytes = totalRemainingBytes
        self.totalSpeed = totalSpeed.isFinite && totalSpeed > 0 ? totalSpeed : 0
        self.aggregateFraction = aggregateFraction.isFinite ? min(max(aggregateFraction, 0), 1) : 0
        self.updatedAt = updatedAt
        self.top = Array(top.prefix(Self.topLimit))
    }

    // Custom decode so a snapshot written before `totalSpeed` existed still reads (the key is
    // simply absent → 0) instead of failing to decode and flashing the widget back to `.empty`.
    // Encoding stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case activeCount, totalRemainingBytes, totalSpeed, aggregateFraction, updatedAt, top
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeCount = try c.decode(Int.self, forKey: .activeCount)
        totalRemainingBytes = try c.decode(Int64.self, forKey: .totalRemainingBytes)
        let rawSpeed = try c.decodeIfPresent(Double.self, forKey: .totalSpeed) ?? 0
        totalSpeed = rawSpeed.isFinite && rawSpeed > 0 ? rawSpeed : 0
        let rawFraction = try c.decode(Double.self, forKey: .aggregateFraction)
        aggregateFraction = rawFraction.isFinite ? min(max(rawFraction, 0), 1) : 0
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        top = try c.decode([Item].self, forKey: .top)
    }

    /// A fixed, deterministic empty value — `updatedAt` is the epoch rather than "now" so two
    /// empty snapshots compare equal and a widget placeholder never flickers.
    public static let empty = SharedSnapshot(
        activeCount: 0,
        totalRemainingBytes: 0,
        aggregateFraction: 0,
        updatedAt: Date(timeIntervalSince1970: 0),
        top: []
    )

    // MARK: - Location

    private static let logger = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "SharedSnapshot")
    private static let fileName = "snapshot.json"

    /// The App Group container, or Application Support when the group is unavailable.
    ///
    /// On the simulator, and on a device without the entitlement provisioned, the group lookup
    /// returns `nil`. That is a degraded mode — the widget will not see the app's writes — but
    /// it must never be a crash and never a block, so we log once per call and continue.
    public static func containerURL() -> URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GoelIdentifiers.appGroup) {
            return url
        }
        logger.warning("App Group \(GoelIdentifiers.appGroup, privacy: .public) unavailable; falling back to Application Support. Widgets will not see live data.")
        return try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    public static func fileURL() -> URL? {
        containerURL()?.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - I/O

    /// Best effort. A failed snapshot write costs the widgets one stale cycle; it must never
    /// take the app down with it.
    public static func write(_ snapshot: SharedSnapshot) {
        guard let url = fileURL() else {
            logger.warning("No container URL; snapshot not written.")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Never throws, never crashes. A missing or corrupt file reads as ``empty``, which is
    /// exactly what a widget should draw when the app has not run yet.
    public static func read() -> SharedSnapshot {
        guard let url = fileURL() else { return .empty }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(SharedSnapshot.self, from: data)
        } catch {
            if (error as NSError).domain != NSCocoaErrorDomain || (error as NSError).code != NSFileReadNoSuchFileError {
                logger.warning("Snapshot read failed, using empty: \(error.localizedDescription, privacy: .public)")
            }
            return .empty
        }
    }
}
