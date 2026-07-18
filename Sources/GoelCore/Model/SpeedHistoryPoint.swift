import Foundation

/// One persisted throughput sample — down/up rates in bytes/sec — used to
/// restore a download's speed chart across quit & relaunch.
///
/// The UI samples throughput once a second into a small ring; that ring is
/// written to the store (keyed by task id) so a chart continues from where it
/// left off instead of starting blank on the next launch. Kept intentionally
/// tiny and self-describing so the persisted blob stays compact and decodes
/// unchanged as the model evolves.
public struct SpeedHistoryPoint: Codable, Sendable, Equatable {
    public var down: Double
    public var up: Double

    public init(down: Double, up: Double) {
        self.down = down
        self.up = up
    }
}
