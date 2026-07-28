import Foundation

/// One persisted throughput sample (down/up bytes/sec): the UI's once-a-second ring, stored by task id,
/// so a speed chart resumes across quit & relaunch instead of starting blank. Kept tiny and self-describing.
public struct SpeedHistoryPoint: Codable, Sendable, Equatable {
    public var down: Double
    public var up: Double

    public init(down: Double, up: Double) {
        self.down = down
        self.up = up
    }
}
