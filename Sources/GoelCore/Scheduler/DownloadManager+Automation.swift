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
        guard settings.scheduleEnabled || settings.pauseBelowBatteryThreshold else { return }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await self?.runAutomation()
            }
        }
    }

    /// Memory is committed BEFORE the loop, or an overlapping tick writes back a stale ledger.
    func runAutomation(feeds: [AutomationCore.FeedFetch] = []) async {
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
                add(source: source, startPaused: startPaused)
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
        let proxy = Self.proxySpec(from: settings)
        for feed in settings.rssFeeds where feed.enabled {
            guard let url = URL(string: feed.url),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            // Never `URLSession.shared` here: this proxies, bounds redirects and refuses link-local.
            guard let data = await NetworkGuard.fetch(url: url, proxy: proxy,
                                                      userAgent: settings.userAgent) else { continue }
            let items = RSSFeedParser.parse(data)
            var candidates: [AutomationCore.FeedCandidate] = []
            for item in items {
                let pattern = feed.titlePattern.trimmingCharacters(in: .whitespaces)
                if !pattern.isEmpty,
                   !item.title.localizedCaseInsensitiveContains(pattern) { continue }
                guard let locator = item.enclosureURL ?? item.link,
                      let source = DownloadSource.parse(locator) else { continue }
                let key = "\(feed.id.uuidString)|\(item.guid ?? locator)"
                candidates.append(.init(key: key, source: source, dedupKey: source.dedupKey))
            }
            candidates.isEmpty ? () : fetches.append(.init(startPaused: feed.startPaused,
                                                           candidates: candidates))
        }
        await runAutomation(feeds: fetches)
    }
}

struct RSSItem: Sendable {
    var title: String
    var link: String?
    var enclosureURL: String?
    var guid: String?
}

final class RSSFeedParser: NSObject, XMLParserDelegate {

    static func parse(_ data: Data) -> [RSSItem] {
        let reader = RSSFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.items
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
            if let href = attributes["href"], current.link == nil { current.link = href }
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
        case "link" where !value.isEmpty: current.link = value
        case "guid", "id": current.guid = value
        case "item", "entry":
            inItem = false
            items.append(current)
        default:
            break
        }
    }
}
