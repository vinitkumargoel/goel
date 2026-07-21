import Foundation

// MARK: - Timer-driven automation

/// The time-of-day download window, network-awareness policy, per-task scheduled
/// starts and the RSS auto-downloader. All four are (re)armed from
/// ``DownloadManager/updateSettings(_:)`` and evaluated on coarse timers; each
/// runs best-effort and can never stall the queue.
///
/// The *decisions* live in the pure ``AutomationCore`` — every tick builds an
/// immutable snapshot, asks ``AutomationCore/decide(_:)`` what to do, then applies
/// the returned actions (re-validating each across the actor's `await`s) and
/// round-trips the single ``AutomationCore/Memory`` value. This file keeps only
/// the impure parts: the timers, the actor mutations, and the RSS fetch/parse.
extension DownloadManager {

    // MARK: Download window

    /// Whether the download window is open at `date` under `settings`. A thin
    /// shim over ``AutomationCore/isWindowOpen(settings:date:calendar:)`` kept for
    /// the manager's synchronous promotion gate (and existing tests).
    static func isWindowOpen(settings: AppSettings, date: Date,
                             calendar: Calendar = .current) -> Bool {
        AutomationCore.isWindowOpen(settings: settings, date: date, calendar: calendar)
    }

    /// (Re)arm the window-evaluation loop per the schedule settings. Disabling the
    /// schedule reopens the window immediately (resuming anything the window had
    /// paused). The promotion gate ``scheduleWindowOpen`` is set synchronously so
    /// ``schedule()`` can't promote into a closed window between this settings
    /// change and the async evaluation; the pause/resume side-effects still run
    /// asynchronously through ``runAutomation(feeds:)``.
    func updateDownloadSchedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard settings.scheduleEnabled else {
            scheduleWindowOpen = true
            Task { await self.runAutomation() }
            return
        }
        scheduleWindowOpen = Self.isWindowOpen(settings: settings, date: Date())
        Task { await self.runAutomation() }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await self?.runAutomation()
            }
        }
    }

    // MARK: The automation tick

    /// Build a snapshot, ask ``AutomationCore`` what to do, and apply it.
    ///
    /// Every timer (window / scheduled-start / RSS) and the network-path callback
    /// funnel through here. Applying a `.pause` re-validates that the task is still
    /// in a download phase — the actor suspends inside ``pause(_:)``, so the user
    /// may have hand-paused a later id meanwhile; such a task must NOT be recorded
    /// (it would be auto-resumed later), so it is dropped from the memory ledger.
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
            feeds: feeds, memory: automationMemory))

        var memory = decision.memory
        for action in decision.actions {
            switch action {
            case .pause(let id, let ledger):
                guard isInDownloadingPhase(id) else {
                    switch ledger {
                    case .window: memory.windowPausedIDs.remove(id)
                    case .network: memory.networkPausedIDs.remove(id)
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
        automationMemory = memory
        scheduleWindowOpen = memory.windowOpen
        publish()
        schedule()
    }

    /// Whether a status occupies a download phase the automation pause loops act
    /// on. Excludes seeding — the window and network policies restrict downloads,
    /// not uploads. Delegates to ``DownloadStatus/isDownloadingPhase``.
    static func isDownloadingPhase(_ status: DownloadStatus) -> Bool {
        status.isDownloadingPhase
    }

    /// Whether the task is currently occupying a download phase.
    func isInDownloadingPhase(_ id: UUID) -> Bool {
        task(id)?.status.isDownloadingPhase ?? false
    }

    /// Narrow profile switch used by automation: set the active profile, persist
    /// it, and push the new limits/config to the engines — deliberately bypassing
    /// the full ``updateSettings(_:)`` cascade (which would re-arm the
    /// schedule/network/backup timers and recurse). Awaited so the profile is in
    /// effect before any subsequent resume promotes a task.
    func setActiveProfile(_ name: String) async {
        settings.selectedProfileName = name
        persistSettings()
        await applyEngineConfigs()
    }

    // MARK: Per-task scheduled starts

    /// Set (or clear, with nil) a one-shot start time on a task. Setting a time
    /// holds the task paused until it fires; an actively-downloading task is
    /// paused first. Clearing leaves the task paused — the user starts it.
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

    /// (Re)arm the scheduled-start loop while any paused task carries a start
    /// time; tear it down when none does. Idempotent and cheap to call from
    /// add/restore/setScheduledStart.
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

    /// Run one automation tick (which fires every paused task whose time has come)
    /// and report whether any scheduled start remains — stopping the loop once
    /// nothing scheduled is left.
    private func fireDueScheduledStarts() async -> Bool {
        await runAutomation()
        let stillPending = tasks.contains { $0.scheduledAt != nil && $0.status == .paused }
        if !stillPending { scheduledStartTask = nil }
        return stillPending
    }

    // MARK: Network awareness

    /// Fold a network-path change (from the app layer's `NWPathMonitor`) into the
    /// queue: entering an expensive/constrained network the user opted out of
    /// pauses every downloading-phase task (recording them); leaving it resumes
    /// exactly those. Settings changes re-evaluate against the last reported path.
    /// The decision itself lives in ``AutomationCore``; this only stores the flags
    /// and runs a tick.
    public func applyNetworkPolicy(expensive: Bool, constrained: Bool) async {
        lastPathExpensive = expensive
        lastPathConstrained = constrained
        await runAutomation()
    }

    // MARK: RSS auto-download

    /// (Re)arm the feed-polling loop when any feed is enabled.
    func updateRSSSchedule() {
        rssTask?.cancel()
        rssTask = nil
        guard settings.rssFeeds.contains(where: \.enabled) else { return }
        let interval = UInt64(max(5, settings.rssPollIntervalMinutes)) * 60 * 1_000_000_000
        Task { await self.pollFeeds() }
        rssTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                await self?.pollFeeds()
            }
        }
    }

    /// Fetch every enabled feed and parse + title-filter its items, then hand the
    /// cooked candidates to ``runAutomation(feeds:)`` — which does the two-layer
    /// dedup (the per-run key set and the persisted-queue ``DownloadSource/dedupKey``)
    /// and queues the new ones. The impure fetch/parse stays here; the dedup +
    /// add decision is pure in ``AutomationCore``.
    func pollFeeds() async {
        var fetches: [AutomationCore.FeedFetch] = []
        let proxy = Self.proxySpec(from: settings)
        for feed in settings.rssFeeds where feed.enabled {
            guard let url = URL(string: feed.url),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            // Guarded auto-fetch: honours the proxy (no IP leak), bounds redirects,
            // strips cross-host headers, and refuses link-local (metadata) targets —
            // unlike the bare `URLSession.shared` this replaced.
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
