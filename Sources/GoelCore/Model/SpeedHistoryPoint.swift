import Foundation

public struct SpeedHistoryPoint: Codable, Sendable, Equatable {
    public var down: Double
    public var up: Double

    public init(down: Double, up: Double) {
        self.down = down
        self.up = up
    }
}
