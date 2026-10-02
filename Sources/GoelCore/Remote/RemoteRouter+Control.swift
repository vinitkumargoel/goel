import Foundation

/// Queue controls, history bulk edits and the schedule. Reached from ``RemoteRouter/handle(_:sessionAuthed:fromTrustedProxy:)``'s
/// fallthrough, so every route here is already past auth, the cross-site check and read-only mode.
extension RemoteRouter {

    /// Caps on request sizes: a portal never sends more, and a script sending more is abuse.
    static let maxBulkIDs = 1000
    static let maxTags = 32
    static let maxTagLength = 64
    static let maxSpeedLimit: Int64 = 100 * 1_000_000_000
    /// A start further out than this is a typo, not a plan.
    static let maxStartAhead: TimeInterval = 366 * 24 * 3600

    static func controlRoute(_ request: RemoteRequest, backend: RemoteBackend) async -> Data? {
        switch (request.method, request.path) {
        case ("POST", "/api/sequential"):
            guard let id = uuid(request.query["id"]) else { return badRequest() }
            await backend.setSequential(truthy(request.query["on"]), task: id)
            return ok()

        case ("POST", "/api/speed-limit"):
            return await speedLimit(request, backend: backend)

        case ("POST", "/api/start-at"):
            return await startAt(request, backend: backend)

        case ("POST", "/api/move"):
            return await move(request, backend: backend)

        case ("POST", "/api/tags"):
            return await tags(request, backend: backend)

        case ("POST", "/api/file-priorities"):
            return await filePriorities(request, backend: backend)

        case ("POST", "/api/history-remove-many"):
            return await historyRemoveMany(request, backend: backend)

        case ("POST", "/api/history-clear"):
            return await historyClear(request, backend: backend)

        case ("POST", "/api/trackers"):
            return await trackers(request, backend: backend)

        case ("GET", "/api/schedule"):
            guard let state = await backend.scheduleState() else { return notFound() }
            return json(state)

        case ("POST", "/api/schedule"):
            return await postSchedule(request, backend: backend)

        case ("GET", "/api/settings"):
            guard let state = await backend.settingsState() else { return notFound() }
            return json(state)

        case ("POST", "/api/settings"):
            return await postSettings(request, backend: backend)

        default:
            return nil
        }
    }

    /// The Add dialog's "download in order" and "start at", applied to what was just queued.
    static func applyAddExtras(_ ids: [String], sequential: Bool?, startAt: Double?,
                               backend: RemoteBackend) async {
        let date = startAt.flatMap { startDate(String($0)) }
        for id in ids.compactMap(UUID.init(uuidString:)) {
            if sequential == true { await backend.setSequential(true, task: id) }
            if let date { await backend.setScheduledStart(date, task: id) }
        }
    }

    static func trackerState(_ status: TorrentTracker.Status) -> String {
        switch status {
        case .working: return "working"
        case .updating: return "updating"
        case .error: return "error"
        case .inactive: return "inactive"
        }
    }

    static func uuid(_ raw: String?) -> UUID? {
        raw.flatMap(UUID.init(uuidString:))
    }

    private static func speedLimit(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let id = uuid(request.query["id"]),
              let bps = request.query["bps"].flatMap(Int64.init),
              (0...maxSpeedLimit).contains(bps)
        else { return badRequest("The limit must be a whole number of bytes per second, 0 for none.") }
        await backend.setTaskSpeedLimit(bps == 0 ? nil : bps, task: id)
        return ok()
    }

    /// `at` is Unix seconds; `at=clear` (or empty) lifts the hold.
    private static func startAt(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let id = uuid(request.query["id"]) else { return badRequest() }
        let raw = request.query["at"] ?? ""
        if raw.isEmpty || raw == "clear" {
            await backend.setScheduledStart(nil, task: id)
            return ok()
        }
        guard let date = startDate(raw) else { return badRequest(startRefusal) }
        await backend.setScheduledStart(date, task: id)
        return ok()
    }

    static let startRefusal = "The start time must be in the future, within a year."

    /// Tolerates a minute of clock skew: "now" from a browser is never exactly now here.
    static func startDate(_ raw: String, now: Date = Date()) -> Date? {
        guard let seconds = Double(raw), seconds.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        let ahead = date.timeIntervalSince(now)
        guard ahead > -60, ahead <= maxStartAhead else { return nil }
        return date
    }

    private struct MovePayload: Decodable {
        var ids: [String]
        var to: String
        var anchor: String?
    }

    private static func move(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let payload = try? JSONDecoder().decode(MovePayload.self, from: request.body),
              !payload.ids.isEmpty, payload.ids.count <= maxBulkIDs
        else { return badRequest() }
        let ids = payload.ids.compactMap(UUID.init(uuidString:))
        guard ids.count == payload.ids.count,
              let placement = placement(payload.to, anchor: payload.anchor)
        else { return badRequest() }
        await backend.remoteMove(ids, to: placement)
        return ok()
    }

    static func placement(_ to: String, anchor: String?) -> QueueOrder.Placement? {
        switch to {
        case "top": return .top
        case "bottom": return .bottom
        case "before": return uuid(anchor).map { .before($0) }
        case "after": return uuid(anchor).map { .after($0) }
        default: return nil
        }
    }

    private struct TagsPayload: Decodable {
        var id: String
        var tags: [String]
    }

    private static func tags(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let payload = try? JSONDecoder().decode(TagsPayload.self, from: request.body),
              let id = uuid(payload.id)
        else { return badRequest() }
        guard let tags = cleanTags(payload.tags) else {
            return badRequest("Up to \(maxTags) tags, each at most \(maxTagLength) characters, no control characters.")
        }
        await backend.setTags(tags, task: id)
        return ok()
    }

    /// nil = refuse the whole list. Blank entries are dropped; the core normalises case and duplicates.
    static func cleanTags(_ raw: [String]) -> [String]? {
        guard raw.count <= maxTags else { return nil }
        var out: [String] = []
        for tag in raw {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard trimmed.count <= maxTagLength else { return nil }
            let control = trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            if control { return nil }
            out.append(trimmed)
        }
        return out
    }

    private struct FilePrioritiesPayload: Decodable {
        var id: String
        var files: [Int]
        var prio: String
    }

    /// One request for a whole folder or "select none" — a 300-file season pack is not 300 POSTs.
    private static func filePriorities(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let payload = try? JSONDecoder().decode(FilePrioritiesPayload.self, from: request.body),
              let id = uuid(payload.id),
              !payload.files.isEmpty, payload.files.count <= 10_000,
              ["skip", "low", "normal", "high"].contains(payload.prio)
        else { return badRequest() }
        guard let task = await backend.task(id) else { return notFound() }
        // Only ids this torrent has: an out-of-range index is refused, not silently ignored.
        let known = Set(task.files.map(\.id))
        let wanted = Set(payload.files)
        guard wanted.isSubset(of: known) else { return badRequest("No such file in this download.") }
        let prio = priority(payload.prio)
        for file in wanted.sorted() {
            await backend.setFilePriority(prio, fileID: file, task: id)
        }
        return ok()
    }

    static let maxTrackerURLs = 200

    private struct TrackerEdit: Decodable {
        var old: String
        var new: String
    }

    private struct TrackersPayload: Decodable {
        var id: String
        var add: [String]?
        var remove: [String]?
        var edit: TrackerEdit?
    }

    private struct TrackersRow: Encodable {
        var added: Int
        var removed: Int
        var edited: Bool
    }

    static let trackerRefusal = "Tracker URLs must be udp, http(s) or ws(s) announce URLs."

    /// Add, remove and rename in one request. Every URL is validated before anything changes, so a bad
    /// entry refuses the whole request rather than half-applying it.
    private static func trackers(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let payload = try? JSONDecoder().decode(TrackersPayload.self, from: request.body),
              let id = uuid(payload.id)
        else { return badRequest() }
        let add = payload.add ?? []
        let remove = payload.remove ?? []
        guard add.count + remove.count <= maxTrackerURLs,
              !add.isEmpty || !remove.isEmpty || payload.edit != nil
        else { return badRequest() }
        let checked = add + remove + [payload.edit?.old, payload.edit?.new].compactMap { $0 }
        guard checked.allSatisfy({ TrackerList.isValidAnnounceURL($0) }) else { return badRequest(trackerRefusal) }

        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var edited = false
        if let edit = payload.edit {
            edited = await backend.editTracker(trim(edit.old), to: trim(edit.new), task: id)
            if !edited { return notFound("No such tracker on this download.") }
        }
        if !remove.isEmpty { await backend.removeTrackers(Set(remove.map(trim)), task: id) }
        let added = add.isEmpty ? 0 : await backend.addTrackers(add.map(trim), task: id)
        return json(TrackersRow(added: added, removed: remove.count, edited: edited))
    }

    private struct IDsPayload: Decodable {
        var ids: [String]
    }

    private static func historyRemoveMany(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let payload = try? JSONDecoder().decode(IDsPayload.self, from: request.body),
              !payload.ids.isEmpty, payload.ids.count <= maxBulkIDs
        else { return badRequest() }
        let ids = payload.ids.compactMap(UUID.init(uuidString:))
        guard ids.count == payload.ids.count else { return badRequest() }
        for id in ids { await backend.removeHistoryEntry(id) }
        return ok()
    }

    private struct ClearPayload: Decodable {
        /// Seconds: entries finished longer ago than this go. nil = everything.
        var olderThan: Double?
    }

    private static func historyClear(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let payload = try? JSONDecoder().decode(ClearPayload.self, from: request.body)
        else { return badRequest() }
        guard let olderThan = payload.olderThan else {
            await backend.clearHistory()
            return ok()
        }
        guard olderThan.isFinite, olderThan >= 0 else { return badRequest() }
        let cutoff = Date().addingTimeInterval(-olderThan)
        let stale = await backend.history(limit: historyLimit).filter { $0.completedAt < cutoff }
        for entry in stale { await backend.removeHistoryEntry(entry.id) }
        return json(ClearedRow(removed: stale.count))
    }

    private struct ClearedRow: Encodable {
        var removed: Int
    }

    private static func postSettings(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard await backend.settingsState() != nil else { return notFound() }
        guard request.body.count <= 16_384,
              let update = try? JSONDecoder().decode(RemoteSettingsUpdate.self, from: request.body)
        else { return badRequest() }
        if let refusal = update.refusal() { return badRequest(refusal) }
        // The same rule as an Add's folder: it must exist, be writable and not be a protected location.
        if let folder = update.requestedFolder, await backend.remoteSaveDirectoryAllowed(folder) == false {
            return forbidden(saveFolderRefusal)
        }
        guard let updated = await backend.updateSettings(update) else { return notFound() }
        return json(updated)
    }

    private static func postSchedule(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let state = await backend.scheduleState() else { return notFound() }
        guard let update = try? JSONDecoder().decode(RemoteScheduleUpdate.self, from: request.body)
        else { return badRequest() }
        if let refusal = update.refusal(against: state) { return badRequest(refusal) }
        guard let updated = await backend.updateSchedule(update) else { return notFound() }
        return json(updated)
    }
}
