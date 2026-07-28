import Foundation

// MARK: - Timer-driven automation

/// Download window, network awareness, scheduled starts and RSS — all (re)armed from
/// ``DownloadManager/updateSettings(_:)``. Decisions are pure in ``AutomationCore``; only timers here.
extension DownloadManager {

    // MARK: Download window

    /// Whether the download window is open at `date`. A shim over
    /// ``AutomationCore/isWindowOpen(settings:date:calendar:)`` for the synchronous promotion gate.
    static func isWindowOpen(settings: AppSettings, date: Date,
                             calendar: Calendar = .current) -> Bool {
        AutomationCore.isWindowOpen(settings: settings, date: date, calendar: calendar)
    }

    /// (Re)arm the window loop. ``scheduleWindowOpen`` is set synchronously so ``schedule()`` can't promote
    /// into a closed window before the async tick; the same 30 s loop re-reads the battery threshold.
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

    // MARK: The automation tick

    /// Build a snapshot, ask ``AutomationCore``, apply. Each `.pause` is re-validated across the actor's
    /// `await`s; memory is committed **before** the loop, or an overlapping tick writes back stale ledgers.
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
                    // Un-record exactly this id rather than rewriting the ledger, so
                    // entries an overlapping tick added meanwhile survive.
                    switch ledger {
                    case .window: automationMemory.windowPausedIDs.remove(id)
                    case .network: automationMemory.networkPausedIDs.remove(id)
                    case .power: automationMemory.powerPausedIDs.remove(id)
                    }
                    continue
                }
                await pause(id)
            case .resume(let id):
                await resume(id)                 // resume() clears scheduledAt
            case .activateProfile(let name):
                await setActiveProfile(name)
            case .add(let source, let startPaused):
                add(source: source, startPaused: startPaused)
            }
        }
        publish()
        schedule()
    }

    /// Whether a status is a download phase the automation pause loops act on. Excludes seeding — these
    /// policies restrict downloads, not uploads. Delegates to ``DownloadStatus/isDownloadingPhase``.
    static func isDownloadingPhase(_ status: DownloadStatus) -> Bool {
        status.isDownloadingPhase
    }

    /// Whether the task is currently occupying a download phase.
    func isInDownloadingPhase(_ id: UUID) -> Bool {
        task(id)?.status.isDownloadingPhase ?? false
    }

    /// Narrow profile switch for automation: set + persist + push to engines, bypassing the full
    /// ``updateSettings(_:)`` cascade (it would re-arm the timers and recurse). Awaited before resumes.
    func setActiveProfile(_ name: String) async {
        var updated = storedSettings
        updated.selectedProfileName = name
        adoptStoredSettings(updated)
        persistSettings()
        await applyEngineConfigs()
    }

    // MARK: Per-task scheduled starts

    /// Set (or clear, with nil) a one-shot start time. Setting holds the task paused until it fires,
    /// pausing an active download first; clearing leaves the task paused — the user starts it.
    public func setScheduledStart(_ date: Date?, task id: DownloadTask.ID) async {
        guard let task = task(id), !task.status.isTerminal else { return }
        if date != nil, task.status != .paused {
            await pause(id)
        }
        // Re-resolve after the possible suspension: pause() may have observed a
        // terminal transition and left the status alone.
        guard let i = index(of: id), !tasks[i].status.isTerminal else { return }
        tasks[i].scheduledAt = date
        persist(tasks[i])
        publish()
        armScheduledStarts()
    }

    /// (Re)arm the scheduled-start loop while any paused task carries a start time; tear it down when
    /// none does. Idempotent and cheap to call from add/restore/setScheduledStart.
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

    /// Run one automation tick (firing every paused task whose time has come) and report whether any
    /// scheduled start remains — the loop stops once nothing scheduled is left.
    private func fireDueScheduledStarts() async -> Bool {
        await runAutomation()
        let stillPending = tasks.contains { $0.scheduledAt != nil && $0.status == .paused }
        if !stillPending { scheduledStartTask = nil }
        return stillPending
    }

    // MARK: Network awareness

    /// Fold an `NWPathMonitor` change into the queue: an opted-out expensive/constrained network pauses
    /// downloading-phase tasks, leaving it resumes exactly those. Decision lives in ``AutomationCore``.
    public func applyNetworkPolicy(expensive: Bool, constrained: Bool) async {
        lastPathExpensive = expensive
        lastPathConstrained = constrained
        await runAutomation()
    }

    // MARK: RSS auto-download

    /// (Re)arm the feed-polling loop when any feed is enabled. Interval clamped to `5…10080` minutes
    /// before the ns conversion: it **traps** on `UInt64` overflow, and an imported backup can set it.
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

    /// Fetch, parse and title-filter every enabled feed, then hand candidates to ``runAutomation(feeds:)``
    /// for the two-layer dedup (per-run keys ∪ queue ``DownloadSource/dedupKey``). Only fetch/parse here.
    func pollFeeds() async {
        var fetches: [AutomationCore.FeedFetch] = []
        let proxy = Self.proxySpec(from: settings)
        for feed in settings.rssFeeds where feed.enabled {
            guard let url = URL(string: feed.url),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            // Guarded auto-fetch: honours the proxy (no IP leak), bounds redirects, strips cross-host
            // headers, refuses link-local (metadata) targets — unlike the `URLSession.shared` it replaced.
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

// MARK: - Minimal RSS/Atom parsing

/// One item pulled from a feed.
struct RSSItem: Sendable {
    var title: String
    var link: String?
    var enclosureURL: String?
    var guid: String?
}

/// A deliberately small RSS 2.0 / Atom reader: titles, links, enclosures and
/// guids — everything the auto-downloader needs, nothing else.
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
