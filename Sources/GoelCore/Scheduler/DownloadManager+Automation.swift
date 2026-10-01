import Foundation

extension DownloadManager {

    static func isWindowOpen(settings: AppSettings, date: Date,
                             calendar: Calendar = .current) -> Bool {
        AutomationCore.isWindowOpen(settings: settings, date: date, calendar: calendar)
    }

    /// `scheduleWindowOpen` is set synchronously, or `schedule()` promotes into a closed window.
    func updateDownloadSchedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        if settings.scheduleEnabled {
            scheduleWindowOpen = Self.isWindowOpen(settings: settings, date: Date())
        } else {
            scheduleWindowOpen = true
        }
        Task { await self.runAutomation() }
        guard settings.scheduleEnabled || settings.pauseBelowBatteryThreshold
                || settings.profileScheduleEnabled else { return }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await self?.runAutomation()
            }
        }
    }

    /// Memory is committed BEFORE the loop, or an overlapping tick writes back a stale ledger.
    /// `inlineLogins` maps a feed item's dedup key to its raw link when that link carries `user:pass@`.
    func runAutomation(feeds: [AutomationCore.FeedFetch] = [],
                       inlineLogins: [String: String] = [:],
                       feedTargets: [String: FeedTarget] = [:]) async {
        let projection = tasks.map { task in
            AutomationCore.TaskPhase(
                id: task.id,
                downloadingPhase: Self.isDownloadingPhase(task.status),
                paused: task.status == .paused,
                terminal: task.status.isTerminal,
                scheduledAt: task.scheduledAt,
                dedupKey: task.source.dedupKey)
        }
        let decision = AutomationCore.decide(.init(
            now: Date(), calendar: .current, settings: settings,
            tasks: projection,
            networkExpensive: lastPathExpensive, networkConstrained: lastPathConstrained,
            onBattery: power.isOnBattery, batteryPercent: power.batteryPercent,
            feeds: feeds, memory: automationMemory))

        automationMemory = decision.memory
        scheduleWindowOpen = decision.memory.windowOpen

        for action in decision.actions {
            switch action {
            case .pause(let id, let ledger):
                guard isInDownloadingPhase(id) else {
                    // Un-record this id only: rewriting the ledger drops an overlapping tick's entries.
                    switch ledger {
                    case .window: automationMemory.windowPausedIDs.remove(id)
                    case .network: automationMemory.networkPausedIDs.remove(id)
                    case .power: automationMemory.powerPausedIDs.remove(id)
                    }
                    continue
                }
                await pause(id)
            case .resume(let id):
                await resume(id)
            case .activateProfile(let name):
                await setActiveProfile(name)
            case .add(let source, let startPaused):
                // Adopted only for what is actually added, not on every poll of every item.
                if let raw = inlineLogins[source.dedupKey] { adoptInlineCredentials(raw) }
                let target = feedTargets[source.dedupKey]
                let folder = target.flatMap { Self.ruleFolder($0.folder) }
                let added = add(source: source, saveDirectory: folder, startPaused: startPaused)
                if let tag = target?.tag, !tag.isEmpty {
                    _ = mutateTask(added.id) { $0.tags = Self.normalizeTags(($0.tags ?? []) + [tag]) }
                }
            }
        }
        publish()
        schedule()
    }

    static func isDownloadingPhase(_ status: DownloadStatus) -> Bool {
        status.isDownloadingPhase
    }

    func isInDownloadingPhase(_ id: UUID) -> Bool {
        task(id)?.status.isDownloadingPhase ?? false
    }

    /// Bypasses ``updateSettings(_:)`` deliberately — that cascade re-arms the timers and recurses.
    func setActiveProfile(_ name: String) async {
        var updated = storedSettings
        updated.selectedProfileName = name
        adoptStoredSettings(updated)
        persistSettings()
        await applyEngineConfigs()
    }

    public func setScheduledStart(_ date: Date?, task id: DownloadTask.ID) async {
        guard let task = task(id), !task.status.isTerminal else { return }
        if date != nil, task.status != .paused {
            await pause(id)
        }
        // Re-resolve after the suspension: pause() may have seen a terminal transition meanwhile.
        guard let i = index(of: id), !tasks[i].status.isTerminal else { return }
        tasks[i].scheduledAt = date
        persist(tasks[i])
        publish()
        armScheduledStarts()
    }

    func armScheduledStarts() {
        let pending = tasks.contains { $0.scheduledAt != nil && $0.status == .paused }
        guard pending else {
            scheduledStartTask?.cancel()
            scheduledStartTask = nil
            return
        }
        guard scheduledStartTask == nil else { return }
        scheduledStartTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                guard let self, await self.fireDueScheduledStarts() else { return }
            }
        }
    }

    private func fireDueScheduledStarts() async -> Bool {
        await runAutomation()
        let stillPending = tasks.contains { $0.scheduledAt != nil && $0.status == .paused }
        if !stillPending { scheduledStartTask = nil }
        return stillPending
    }

    public func applyNetworkPolicy(expensive: Bool, constrained: Bool) async {
        lastPathExpensive = expensive
        lastPathConstrained = constrained
        await runAutomation()
    }

    /// Clamp to 5…10080 minutes before the ns conversion: `UInt64` traps, and a backup can set it.
    func updateRSSSchedule() {
        updateTrackerListSchedule()
        rssTask?.cancel()
        rssTask = nil
        guard settings.rssFeeds.contains(where: \.enabled) else { return }
        let minutes = min(max(5, settings.rssPollIntervalMinutes), 10_080)
        let interval = UInt64(minutes) * 60 * 1_000_000_000
        Task { await self.pollFeeds() }
        rssTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                await self?.pollFeeds()
            }
        }
    }

    func pollFeeds() async {
        var fetches: [AutomationCore.FeedFetch] = []
        var inlineLogins: [String: String] = [:]
        var feedTargets: [String: FeedTarget] = [:]
        let proxy = Self.proxySpec(from: settings)
        for feed in settings.rssFeeds where feed.enabled {
            guard let url = URL(string: feed.url),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            // Never `URLSession.shared` here: this proxies, bounds redirects and refuses link-local.
            guard let data = await NetworkGuard.fetch(url: url, proxy: proxy, userAgent: settings.userAgent,
                                                      maxBytes: RSSFeedParser.maxFeedBytes) else { continue }
            let items = RSSFeedParser.parse(data)
            var candidates: [AutomationCore.FeedCandidate] = []
            for item in items {
                guard RSSRuleMatcher.matches(title: item.title, feed: feed) else { continue }
                guard let locator = item.enclosureURL ?? item.link,
                      let parsed = DownloadSource.parseWithCredentials(locator) else { continue }
                let source = parsed.source
                if parsed.authorization != nil { inlineLogins[source.dedupKey] = locator }
                let folder = feed.saveDirectory.trimmingCharacters(in: .whitespaces)
                let tag = feed.tag.trimmingCharacters(in: .whitespaces)
                if !folder.isEmpty || !tag.isEmpty {
                    feedTargets[source.dedupKey] = FeedTarget(folder: folder, tag: tag)
                }
                let key = "\(feed.id.uuidString)|\(item.guid ?? locator)"
                candidates.append(.init(key: key, source: source, dedupKey: source.dedupKey))
            }
            candidates.isEmpty ? () : fetches.append(.init(startPaused: feed.startPaused,
                                                           candidates: candidates))
        }
        await runAutomation(feeds: fetches, inlineLogins: inlineLogins, feedTargets: feedTargets)
    }
}

/// A feed's folder/tag for what it adds, keyed by dedup key beside the automation decision.
struct FeedTarget: Sendable, Equatable {
    var folder: String
    var tag: String
}

public struct RSSItem: Sendable, Equatable {
    public var title: String
    public var link: String?
    public var enclosureURL: String?
    public var guid: String?
    public var summary: String?
    public var published: String?

    public init(title: String, link: String? = nil, enclosureURL: String? = nil, guid: String? = nil,
                summary: String? = nil, published: String? = nil) {
        self.title = title
        self.link = link
        self.enclosureURL = enclosureURL
        self.guid = guid
        self.summary = summary
        self.published = published
    }

    /// Stable identity for "read" state: the guid, else the download locator, else the title.
    public var key: String { guid ?? enclosureURL ?? link ?? title }
    /// What a download would start from.
    public var locator: String? { enclosureURL ?? link }
}

extension DownloadManager {
    /// The RSS reader's fetch: same proxy, user agent and target screening as the poller.
    public func fetchFeedItems(_ address: String) async throws -> [RSSItem] {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { throw URLError(.badURL) }
        let data = try await NetworkGuard.fetchChecked(url: url, proxy: Self.proxySpec(from: settings),
                                                       userAgent: settings.userAgent,
                                                       maxBytes: RSSFeedParser.maxFeedBytes)
        return RSSFeedReader.parse(data)
    }
}

/// The app's RSS reader parses with the same rules the poller uses.
public enum RSSFeedReader {
    public static func parse(_ data: Data) -> [RSSItem] { RSSFeedParser.parse(data) }
}

final class RSSFeedParser: NSObject, XMLParserDelegate {

    /// A feed is a few hundred KB; anything past this is hostile or not a feed.
    static let maxFeedBytes = 5 * 1024 * 1024
    /// Newest-first feeds put what matters at the top; the rest is never looked at.
    static let maxItems = 500

    static func parse(_ data: Data) -> [RSSItem] {
        let reader = RSSFeedParser()
        let parser = XMLParser(data: data)
        // Explicit, whatever the platform default: a feed must never make us fetch a DTD or entity.
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        parser.parse()
        return reader.items
    }

    /// `link` is what the reader opens in a browser, so it only ever holds http(s). A magnet in
    /// `<link>` (common in torrent feeds) is a download locator and moves to the enclosure slot.
    static func accept(link raw: String, into item: inout RSSItem) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: value)?.scheme?.lowercased() else { return }
        if scheme == "http" || scheme == "https" {
            item.link = value
        } else if scheme == "magnet", item.enclosureURL == nil {
            item.enclosureURL = value
        }
    }

    private var items: [RSSItem] = []
    private var inItem = false
    private var current = RSSItem(title: "")
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "item", "entry":
            inItem = true
            current = RSSItem(title: "")
        case "enclosure" where inItem:
            current.enclosureURL = attributes["url"]
        case "link" where inItem:
            // Atom links carry the target in `href`; RSS links carry it in text.
            if let href = attributes["href"], current.link == nil { Self.accept(link: href, into: &current) }
        default:
            break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        guard inItem else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": current.title = value
        case "link" where !value.isEmpty: Self.accept(link: value, into: &current)
        case "guid", "id": current.guid = value
        case "description", "summary", "content":
            if current.summary == nil, !value.isEmpty { current.summary = value }
        case "pubDate", "published", "updated":
            if current.published == nil, !value.isEmpty { current.published = value }
        case "item", "entry":
            inItem = false
            items.append(current)
            if items.count >= Self.maxItems { parser.abortParsing() }
        default:
            break
        }
    }
}
