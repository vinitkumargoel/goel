import Foundation

/// One RSS/Atom feed the auto-downloader watches. Items whose title matches
/// ``titlePattern`` (case-insensitive substring; empty = every item) have their
/// enclosure/link queued automatically.
public struct RSSFeed: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var url: String
    public var titlePattern: String
    public var enabled: Bool

    /// Add matched items paused so the user reviews them before bytes move.
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
