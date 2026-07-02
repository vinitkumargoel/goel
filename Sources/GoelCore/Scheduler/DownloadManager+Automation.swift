import Foundation

// MARK: - Timer-driven automation

/// The time-of-day download window and the RSS auto-downloader. Both are
/// (re)armed from ``DownloadManager/updateSettings(_:)`` and evaluated on
/// coarse timers; each runs best-effort and can never stall the queue.
extension DownloadManager {

    // MARK: Download window

    /// Whether the download window is open at `date` under `settings`. Pure so
    /// tests can drive the day/time matrix directly. A disabled schedule — or a
    /// degenerate window whose start equals its end — is always open; an end
    /// before the start wraps past midnight (22:00 → 07:00).
    static func isWindowOpen(settings: AppSettings, date: Date,
                             calendar: Calendar = .current) -> Bool {
        guard settings.scheduleEnabled else { return true }
        let start = settings.scheduleStartMinute
        let end = settings.scheduleEndMinute
        guard start != end else { return true }
        guard settings.scheduleDays.contains(calendar.component(.weekday, from: date)) else {
            return false
        }
        let minutes = calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
        return start < end
            ? (minutes >= start && minutes < end)
            : (minutes >= start || minutes < end)
    }

    /// (Re)arm the window-evaluation loop per the schedule settings. Disabling
    /// the schedule reopens the window immediately (resuming anything the
    /// window had paused).
    func updateDownloadSchedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard settings.scheduleEnabled else {
            if !scheduleWindowOpen {
                scheduleWindowOpen = true
                Task { await self.applyWindowTransition(open: true) }
            }
            return
        }
        // Set the gate synchronously so schedule() can't promote into a closed
        // window between this settings change and the async evaluation; the
        // pause/resume side-effects still run asynchronously.
        let openNow = Self.isWindowOpen(settings: settings, date: Date())
        if openNow != scheduleWindowOpen {
            scheduleWindowOpen = openNow
            Task { await self.applyWindowTransition(open: openNow) }
        }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await self?.evaluateDownloadWindow()
            }
        }
    }

    func evaluateDownloadWindow() async {
        let open = Self.isWindowOpen(settings: settings, date: Date())
        guard open != scheduleWindowOpen else { return }
        scheduleWindowOpen = open
        await applyWindowTransition(open: open)
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

    /// Start every paused task whose time has come. Returns false — stopping
    /// the loop — once nothing scheduled remains.
    private func fireDueScheduledStarts() async -> Bool {
        let now = Date()
        let due = tasks
            .filter { $0.status == .paused && ($0.scheduledAt ?? .distantFuture) <= now }
            .map(\.id)
        for id in due {
            await resume(id)   // resume() clears scheduledAt
        }
        let stillPending = tasks.contains { $0.scheduledAt != nil && $0.status == .paused }
        if !stillPending { scheduledStartTask = nil }
        return stillPending
    }

    /// Cross the window edge: closing pauses every downloading-phase task
    /// (recording them, so a hand-paused task is never resumed by the window)
    /// and restores the pre-window profile; opening switches to the schedule's
    /// profile and resumes exactly the recorded tasks.
    private func applyWindowTransition(open: Bool) async {
        if open {
            let scheduleProfile = settings.scheduleProfileName
            if !scheduleProfile.isEmpty,
               settings.profiles.contains(where: { $0.name == scheduleProfile }),
               settings.selectedProfileName != scheduleProfile {
                preScheduleProfileName = settings.selectedProfileName
                settings.selectedProfileName = scheduleProfile
                persistSettings()
                await applyEngineConfigs()
            }
            let ids = schedulePausedIDs
            schedulePausedIDs = []
            for id in ids { await resume(id) }
            publish()
            schedule()
        } else {
            if let previous = preScheduleProfileName {
                preScheduleProfileName = nil
                // Only restore if the window's own profile is still active — a
                // manual profile change made while the window was open wins.
                if settings.selectedProfileName == settings.scheduleProfileName,
                   settings.profiles.contains(where: { $0.name == previous }) {
                    settings.selectedProfileName = previous
                    persistSettings()
                    await applyEngineConfigs()
                }
            }
            let ids = tasks
                .filter { task in
                    switch task.status {
                    case .downloading, .verifying, .requestingMetadata: return true
                    default: return false
                    }
                }
                .map(\.id)
            for id in ids {
                // Re-validate per iteration: the actor suspends inside pause(),
                // so the user may have hand-paused a later id meanwhile — that
                // task must NOT be recorded (it would be auto-resumed later).
                guard isInDownloadingPhase(id) else { continue }
                await pause(id)
                schedulePausedIDs.insert(id)
            }
            publish()
        }
    }

    /// Whether the task is currently occupying a download phase (the statuses
    /// the automation pause loops act on). Excludes seeding — the window and
    /// network policies restrict downloads, not uploads.
    private func isInDownloadingPhase(_ id: UUID) -> Bool {
        switch task(id)?.status {
        case .downloading, .verifying, .requestingMetadata: return true
        default: return false
        }
    }

    // MARK: Network awareness

    /// Fold a network-path change (from the app layer's `NWPathMonitor`) into
    /// the queue: entering an expensive/constrained network the user opted out
    /// of pauses every downloading-phase task (recording them); leaving it
    /// resumes exactly those. Settings changes re-evaluate against the last
    /// reported path.
    public func applyNetworkPolicy(expensive: Bool, constrained: Bool) async {
        lastPathExpensive = expensive
        lastPathConstrained = constrained
        let shouldPause = (settings.pauseOnExpensiveNetwork && expensive)
            || (settings.pauseOnConstrainedNetwork && constrained)
        if shouldPause, !networkPaused {
            networkPaused = true
            let ids = tasks
                .filter { task in
                    switch task.status {
                    case .downloading, .verifying, .requestingMetadata: return true
                    default: return false
                    }
                }
                .map(\.id)
            for id in ids {
                // Same re-validation as the window close: a task the user
                // paused during this loop's suspensions is theirs, not ours.
                guard isInDownloadingPhase(id) else { continue }
                await pause(id)
                networkPausedIDs.insert(id)
            }
            publish()
        } else if !shouldPause, networkPaused {
            networkPaused = false
            let ids = networkPausedIDs
            networkPausedIDs = []
            for id in ids { await resume(id) }
            publish()
        }
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

    /// Fetch every enabled feed, queue new matching items, and remember what
    /// was seen. Duplicate protection is two-layer: the per-item key set (this
    /// run of the app) and ``add(source:saveDirectory:priority:)``'s dedup
    /// against the persisted queue (across relaunches, while the task exists).
    func pollFeeds() async {
        for feed in settings.rssFeeds where feed.enabled {
            guard let url = URL(string: feed.url),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { continue }
            let items = RSSFeedParser.parse(data)
            for item in items {
                let pattern = feed.titlePattern.trimmingCharacters(in: .whitespaces)
                if !pattern.isEmpty,
                   !item.title.localizedCaseInsensitiveContains(pattern) { continue }
                guard let locator = item.enclosureURL ?? item.link,
                      let source = DownloadSource.parse(locator) else { continue }
                let key = "\(feed.id.uuidString)|\(item.guid ?? locator)"
                guard !rssSeenKeys.contains(key) else { continue }
                rssSeenKeys.insert(key)
                let existing = tasks.contains { $0.source.dedupKey == source.dedupKey }
                guard !existing else { continue }
                // startPaused rides through add() so the scheduler never
                // optimistically promotes an item the feed wants held.
                add(source: source, startPaused: feed.startPaused)
            }
        }
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
