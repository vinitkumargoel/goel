import Foundation

public struct RSSFeed: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var url: String
    public var titlePattern: String
    public var enabled: Bool

    public var startPaused: Bool

    public init(id: UUID = UUID(), url: String, titlePattern: String = "",
                enabled: Bool = true, startPaused: Bool = false) {
        self.id = id
        self.url = url
        self.titlePattern = titlePattern
        self.enabled = enabled
        self.startPaused = startPaused
    }
}
