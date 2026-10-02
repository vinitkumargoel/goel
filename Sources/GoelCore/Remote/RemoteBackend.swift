import Foundation

public protocol RemoteBackend: AnyObject, Sendable {
    func taskSnapshot() async -> [DownloadTask]
    func task(_ id: UUID) async -> DownloadTask?
    func pauseAll() async
    func resumeAll() async
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func retry(_ id: UUID) async
    func remove(_ id: UUID, deleteData: Bool) async
    func forceRecheck(_ id: UUID) async
    func setSequential(_ sequential: Bool, task id: UUID) async
    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async
    func remoteAdd(source: DownloadSource) async
    func remoteAdd(source: DownloadSource, saveDirectory: String?,
                   priority: FilePriority, startPaused: Bool) async
    func history(limit: Int) async -> [HistoryEntry]
    /// One entry by id, for `/stream?history=`. The default looks only through what `/api/history`
    /// lists, so a request costs no more than the list the portal already loaded.
    func historyEntry(_ id: UUID) async -> HistoryEntry?
    /// Folders a history download may sit in but never be served as a whole (the default save
    /// folder, home). Empty = no such roots.
    func remoteDownloadRoots() async -> [String]
    func removeHistoryEntry(_ id: UUID) async
    func clearHistory() async
    /// The default implementation returns `true` — a conformer that forgets this allows every folder.
    func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool

    /// Whether an added name will be resolved by a SOCKS5 proxy rather than by this host, which decides
    /// whether the router's local-resolution screen means anything. Defaults to `false` — a backend that
    /// cannot answer stays fail-closed rather than claiming a proxy it has not got.
    func remoteAddResolvesThroughProxy() async -> Bool

    func networkState() async -> RemoteNetworkState
    func updateAggregation(enabled: Bool?, adapterIds: [String]?, streams: Int?) async
    /// Returns the queued task's ID (or the existing task's, when the source deduplicates)
    /// so `/api/add` can hand callers something they can poll. nil = backend cannot say.
    @discardableResult
    func remoteAdd(source: DownloadSource, saveDirectory: String?, priority: FilePriority,
                   startPaused: Bool, network: NetworkSelection?) async -> UUID?

    /// Reach is bounded by the server uid, not by a root of ours.
    func folderListing(_ path: String?) async -> RemoteFolderListing?
    func createFolder(named name: String, in parent: String?) async -> String?

    /// nil = this backend has no speed limiter to expose; the route answers 404.
    func bandwidthState() async -> RemoteBandwidthState?
    /// Called only after the router validated `update` against ``bandwidthState()``.
    func updateBandwidth(_ update: RemoteBandwidthUpdate) async -> RemoteBandwidthState?

    /// Queues an uploaded .torrent (already screened by the router). Returns the task's ID, or nil when the
    /// backend cannot say; throws ``RemoteTorrentUpload/Failure`` when it could not be queued at all.
    func remoteAddTorrent(_ data: Data, named name: String, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool) async throws -> UUID?
    /// As above, bound to `network` like `/api/add`; the default drops the choice for older conformers.
    func remoteAddTorrent(_ data: Data, named name: String, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool,
                          network: NetworkSelection?) async throws -> UUID?

    // Queue controls. Each defaults to a no-op, so an older conformer answers 200 and changes nothing.
    /// nil or 0 lifts the per-download cap.
    func setTaskSpeedLimit(_ bytesPerSec: Int64?, task id: UUID) async
    func setTags(_ tags: [String], task id: UUID) async
    /// Holds the task paused until `date`; nil clears the hold.
    func setScheduledStart(_ date: Date?, task id: UUID) async
    func remoteMove(_ ids: [UUID], to placement: QueueOrder.Placement) async
    /// nil = no scheduler to expose; the route answers 404.
    func scheduleState() async -> RemoteScheduleState?
    /// Called only after the router validated `update` against ``scheduleState()``.
    func updateSchedule(_ update: RemoteScheduleUpdate) async -> RemoteScheduleState?
    /// nil = no editable settings to expose; the routes answer 404.
    func settingsState() async -> RemoteSettingsState?
    /// Called only after the router validated `update` and vetted its folder.
    func updateSettings(_ update: RemoteSettingsUpdate) async -> RemoteSettingsState?
    /// nil = no editable rules to expose; the routes answer 404.
    func rulesState() async -> [AutoSortRule]?
    /// Called only after the router validated and vetted the list; replaces the stored rules, returns them.
    func replaceRules(_ rules: [AutoSortRule]) async -> [AutoSortRule]?
    // Tracker editing; URLs arrive already checked with `TrackerList.isValidAnnounceURL`.
    /// How many were new to the torrent.
    func addTrackers(_ urls: [String], task id: UUID) async -> Int
    func removeTrackers(_ urls: Set<String>, task id: UUID) async
    /// False when `old` isn't one of the torrent's trackers.
    func editTracker(_ old: String, to new: String, task id: UUID) async -> Bool
}

public extension RemoteBackend {
    func setTaskSpeedLimit(_ bytesPerSec: Int64?, task id: UUID) async {}
    func setTags(_ tags: [String], task id: UUID) async {}
    func setScheduledStart(_ date: Date?, task id: UUID) async {}
    func remoteMove(_ ids: [UUID], to placement: QueueOrder.Placement) async {}
    func scheduleState() async -> RemoteScheduleState? { nil }
    func updateSchedule(_ update: RemoteScheduleUpdate) async -> RemoteScheduleState? { nil }
    func settingsState() async -> RemoteSettingsState? { nil }
    func updateSettings(_ update: RemoteSettingsUpdate) async -> RemoteSettingsState? { nil }
    func rulesState() async -> [AutoSortRule]? { nil }
    func replaceRules(_ rules: [AutoSortRule]) async -> [AutoSortRule]? { nil }
    func addTrackers(_ urls: [String], task id: UUID) async -> Int { 0 }
    func removeTrackers(_ urls: Set<String>, task id: UUID) async {}
    func editTracker(_ old: String, to new: String, task id: UUID) async -> Bool { false }
    func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool { true }
    func historyEntry(_ id: UUID) async -> HistoryEntry? {
        await history(limit: RemoteRouter.historyLimit).first { $0.id == id }
    }
    func remoteDownloadRoots() async -> [String] { [] }
    func remoteAddResolvesThroughProxy() async -> Bool { false }
    func folderListing(_ path: String?) async -> RemoteFolderListing? { nil }
    func createFolder(named name: String, in parent: String?) async -> String? { nil }
    func networkState() async -> RemoteNetworkState { RemoteNetworkState() }
    func updateAggregation(enabled: Bool?, adapterIds: [String]?, streams: Int?) async {}
    func bandwidthState() async -> RemoteBandwidthState? { nil }
    func updateBandwidth(_ update: RemoteBandwidthUpdate) async -> RemoteBandwidthState? { nil }
    func remoteAddTorrent(_ data: Data, named name: String, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool) async throws -> UUID? {
        throw RemoteTorrentUpload.Failure.unsupported
    }
    func remoteAddTorrent(_ data: Data, named name: String, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool,
                          network: NetworkSelection?) async throws -> UUID? {
        try await remoteAddTorrent(data, named: name, saveDirectory: saveDirectory,
                                   priority: priority, startPaused: startPaused)
    }
    @discardableResult
    func remoteAdd(source: DownloadSource, saveDirectory: String?, priority: FilePriority,
                   startPaused: Bool, network: NetworkSelection?) async -> UUID? {
        await remoteAdd(source: source, saveDirectory: saveDirectory,
                        priority: priority, startPaused: startPaused)
        return nil
    }
}

public struct RemoteFolderListing: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public var name: String
        public var path: String
        public var readable: Bool
        public var writable: Bool

        public init(name: String, path: String, readable: Bool = true, writable: Bool = true) {
            self.name = name
            self.path = path
            self.readable = readable
            self.writable = writable
        }
    }

    public var path: String
    public var parent: String?
    public var folders: [Entry]
    public var writable: Bool
    public var home: String
    public var defaultFolder: String
    public var places: [Entry]

    public init(path: String, parent: String?, folders: [Entry], writable: Bool,
                home: String, defaultFolder: String, places: [Entry]) {
        self.path = path
        self.parent = parent
        self.folders = folders
        self.writable = writable
        self.home = home
        self.defaultFolder = defaultFolder
        self.places = places
    }
}

public struct RemoteNetworkState: Sendable, Codable, Equatable {
    public struct Adapter: Sendable, Codable, Equatable {
        public var name: String
        public var label: String
        public var type: String
        public var ipv4: String?
        public var expensive: Bool
        public var eligible: Bool

        public init(name: String, label: String, type: String, ipv4: String?,
                    expensive: Bool, eligible: Bool) {
            self.name = name
            self.label = label
            self.type = type
            self.ipv4 = ipv4
            self.expensive = expensive
            self.eligible = eligible
        }
    }

    public var aggregation: Bool
    public var streamsPerAdapter: Int
    public var selected: [String]
    public var reason: String?
    /// `/etc/goel/config` pins `GOEL_AGGREGATION` — a change made here lasts only until the next restart.
    public var locked: Bool
    public var adapters: [Adapter]

    public init(aggregation: Bool = false, streamsPerAdapter: Int = 2,
                selected: [String] = [], reason: String? = nil, locked: Bool = false,
                adapters: [Adapter] = []) {
        self.aggregation = aggregation
        self.streamsPerAdapter = streamsPerAdapter
        self.selected = selected
        self.reason = reason
        self.locked = locked
        self.adapters = adapters
    }
}

extension DownloadManager: RemoteBackend {
    public func taskSnapshot() async -> [DownloadTask] { snapshot }
    public func remoteAdd(source: DownloadSource) async { _ = add(source: source, saveDirectory: nil) }
    public func remoteAdd(source: DownloadSource, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool) async {
        _ = add(source: source, saveDirectory: remoteSaveDirectory(saveDirectory),
                priority: priority, startPaused: startPaused)
    }

    @discardableResult
    public func remoteAdd(source: DownloadSource, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool,
                          network: NetworkSelection?) async -> UUID? {
        add(source: source, saveDirectory: remoteSaveDirectory(saveDirectory),
            priority: priority, startPaused: startPaused, network: network).id
    }

    public func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool {
        let defaultFolder = settings.defaultSaveDirectory
        return await Task.detached(priority: .userInitiated) {
            SaveFolderBrowser.canSave(into: folder, defaultFolder: defaultFolder)
        }.value
    }

    public func remoteMove(_ ids: [UUID], to placement: QueueOrder.Placement) async {
        moveInQueue(ids, to: placement)
    }

    public func scheduleState() async -> RemoteScheduleState? {
        RemoteScheduleState(settings)
    }

    /// Through `apply`: it edits ``storedSettings`` in one actor turn, so only the schedule fields change —
    /// a concurrent edit elsewhere isn't overwritten, and MDM-forced values aren't written back as stored.
    public func updateSchedule(_ update: RemoteScheduleUpdate) async -> RemoteScheduleState? {
        let updated = await apply { update.apply(to: &$0) }
        return RemoteScheduleState(updated)
    }

    public func settingsState() async -> RemoteSettingsState? {
        RemoteSettingsState(settings)
    }

    /// Through `apply`, like the schedule: only these fields change, and MDM-forced values aren't stored.
    public func updateSettings(_ update: RemoteSettingsUpdate) async -> RemoteSettingsState? {
        let updated = await apply { update.apply(to: &$0) }
        return RemoteSettingsState(updated)
    }

    public func rulesState() async -> [AutoSortRule]? {
        settings.autoSortRules
    }

    /// Through `apply`, like settings: only the rule list is written, from the desktop's own store.
    public func replaceRules(_ rules: [AutoSortRule]) async -> [AutoSortRule]? {
        await apply { $0.autoSortRules = rules }.autoSortRules
    }

    public func remoteDownloadRoots() async -> [String] {
        [settings.defaultSaveDirectory, NSHomeDirectory()]
    }

    public func remoteAddResolvesThroughProxy() async -> Bool {
        NetworkGuard.usesRemoteDNS(Self.proxySpec(from: settings))
    }

    // These must hop off the actor: stat-ing a network-mounted folder would stall every download.
    public func folderListing(_ path: String?) async -> RemoteFolderListing? {
        let defaultFolder = settings.defaultSaveDirectory
        return await Task.detached(priority: .userInitiated) {
            SaveFolderBrowser.listing(
                of: path, defaultFolder: defaultFolder, home: NSHomeDirectory())
        }.value
    }

    public func createFolder(named name: String, in parent: String?) async -> String? {
        let defaultFolder = settings.defaultSaveDirectory
        return await Task.detached(priority: .userInitiated) {
            SaveFolderBrowser.create(named: name, in: parent, defaultFolder: defaultFolder,
                                     home: NSHomeDirectory())
        }.value
    }

    public func networkState() async -> RemoteNetworkState {
        let all = AdapterDirectory.enumerate()
        let bindable = Set(Self.bindableAdapters(
            settings: settings, vpnDefaultRoute: vpnDefaultRouteActive, all: all)
            .map(\.bsdName))
        return RemoteNetworkState(
            aggregation: settings.aggregationEnabled,
            streamsPerAdapter: settings.aggregationStreamsPerAdapter,
            selected: settings.aggregationAdapterIds,
            reason: Self.aggregationSinglePathReason(
                settings: settings, vpnDefaultRoute: vpnDefaultRouteActive, adapters: all)?.rawValue,
            locked: ProcessInfo.processInfo.environment["GOEL_AGGREGATION"] != nil,
            adapters: all.map {
                RemoteNetworkState.Adapter(
                    name: $0.bsdName, label: $0.shortLabel, type: $0.type, ipv4: $0.ipv4,
                    expensive: $0.isExpensive, eligible: bindable.contains($0.bsdName))
            })
    }

    public func updateAggregation(enabled: Bool?, adapterIds: [String]?, streams: Int?) async {
        var updated = settings
        if let enabled { updated.aggregationEnabled = enabled }
        if let adapterIds {
            updated.aggregationAdapterIds = adapterIds.filter(NetworkSelection.isValidInterfaceName)
        }
        if let streams { updated.aggregationStreamsPerAdapter = min(8, max(1, streams)) }
        await updateSettings(updated)
    }

    /// The filesystem decides, minus ``SaveFolderBrowser/isProtected(_:home:defaultFolder:)`` locations.
    func remoteSaveDirectory(_ folder: String?) -> String? {
        guard let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty else { return nil }
        if SaveFolderBrowser.canSave(into: folder, defaultFolder: settings.defaultSaveDirectory) {
            return folder
        }
        GoelLog.remote.error("Remote add: save folder is not writable or is protected; using default",
                             .path(folder))
        return nil
    }
}
