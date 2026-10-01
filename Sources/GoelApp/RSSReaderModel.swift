import Foundation
import GoelCore

/// State behind the RSS sidebar destination: which feed is open, its fetched articles, and
/// which articles have been read (per-Mac, in UserDefaults, capped).
@MainActor
final class RSSReaderModel: ObservableObject {
    static let shared = RSSReaderModel()

    @Published var isOpen = false
    @Published var selectedFeed: RSSFeed.ID?
    @Published var selectedArticle: String?
    @Published private(set) var articles: [RSSFeed.ID: [RSSItem]] = [:]
    @Published private(set) var errors: [RSSFeed.ID: String] = [:]
    @Published private(set) var loading: Set<RSSFeed.ID> = []
    @Published private(set) var readKeys: Set<String>

    private static let readKey = "rss.readArticles"
    private static let readCap = 5_000
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        readKeys = Set(defaults.stringArray(forKey: Self.readKey) ?? [])
    }

    func open(feed: RSSFeed.ID? = nil) {
        if let feed { selectedFeed = feed }
        isOpen = true
    }

    func close() { isOpen = false }

    func unreadCount(_ feed: RSSFeed.ID) -> Int {
        (articles[feed] ?? []).filter { !readKeys.contains($0.key) }.count
    }

    func markRead(_ item: RSSItem) {
        guard !readKeys.contains(item.key) else { return }
        readKeys.insert(item.key)
        persistRead()
    }

    func markAllRead(_ feed: RSSFeed.ID) {
        readKeys.formUnion((articles[feed] ?? []).map(\.key))
        persistRead()
    }

    private func persistRead() {
        // Cap: an old feed's keys fall off first only approximately (sets are unordered); good enough.
        let list = Array(readKeys.prefix(Self.readCap))
        defaults.set(list, forKey: Self.readKey)
    }

    func refresh(_ feed: RSSFeed, using manager: DownloadManager) async {
        guard !loading.contains(feed.id) else { return }
        loading.insert(feed.id)
        defer { loading.remove(feed.id) }
        do {
            articles[feed.id] = try await manager.fetchFeedItems(feed.url)
            errors[feed.id] = nil
        } catch {
            let reason = (error as? NetworkGuard.FetchError)?.description ?? error.localizedDescription
            errors[feed.id] = L10n.t("Couldn’t load the feed — %@", reason)
        }
    }
}

/// Plain text for the preview pane: RSS summaries are HTML fragments.
enum RSSText {
    /// Only web pages open from a feed: a `file:`, `smb:` or custom-scheme link is never handed to
    /// the system, whatever the parser let through.
    static func browserURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func plain(_ html: String?) -> String {
        guard var text = html, !text.isEmpty else { return "" }
        text = text.replacingOccurrences(of: "<br ?/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
