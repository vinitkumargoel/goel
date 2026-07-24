import Foundation
import Observation
import OSLog
import SwiftUI

/// How the engine is allowed to behave. Owned by Settings (T12), read by the engine (T05).
/// A setting that nothing reads is worse than no setting, so this is the single struct that
/// carries every tunable across the seam.
public struct EngineTuning: Sendable, Equatable, Codable {
    public var trafficProfile: TrafficProfile
    public var maxConnections: Int              // 1...8
    public var speedLimitBytesPerSec: Int64?    // nil = unlimited
    public var allowCellular: Bool
    public var finishOnWiFi: Bool
    public var verifyChecksums: Bool

    public init(
        trafficProfile: TrafficProfile = .balanced,
        maxConnections: Int = 6,
        speedLimitBytesPerSec: Int64? = nil,
        allowCellular: Bool = false,
        finishOnWiFi: Bool = true,
        verifyChecksums: Bool = true
    ) {
        self.trafficProfile = trafficProfile
        self.maxConnections = min(max(maxConnections, 1), 8)
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
        self.allowCellular = allowCellular
        self.finishOnWiFi = finishOnWiFi
        self.verifyChecksums = verifyChecksums
    }

    public static let `default` = EngineTuning()

    private static let defaultsKey = "dev.goel.ios.engineTuning"

    public static func load(from defaults: UserDefaults = .standard) -> EngineTuning {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(EngineTuning.self, from: data)
        else { return .default }
        return decoded
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

public enum TrafficProfile: String, Codable, Sendable, CaseIterable {
    case conservative, balanced, aggressive

    public var displayName: String {
        switch self {
        case .conservative: "Conservative"
        case .balanced: "Balanced"
        case .aggressive: "Aggressive"
        }
    }

    /// Connection count this profile prefers, before the explicit max-connections clamp.
    public var connections: Int {
        switch self {
        case .conservative: 2
        case .balanced: 6
        case .aggressive: 8
        }
    }

    /// Read buffer per connection.
    public var chunkSize: Int {
        switch self {
        case .conservative: 32 * 1024
        case .balanced: 128 * 1024
        case .aggressive: 512 * 1024
        }
    }

    public var detail: String {
        switch self {
        case .conservative: "2 connections · gentle on the network"
        case .balanced: "6 connections · the default"
        case .aggressive: "8 connections · saturate the link"
        }
    }
}

/// The composition root. Owns the store and the engine, pumps engine events into the store,
/// and holds the navigation state the tabs share.
@MainActor
@Observable
public final class AppModel {
    public let store: DownloadStore
    public let engine: any TransferEngine

    public var selectedTab: Tab = .downloads
    public var queuePath: [UUID] = []
    public var libraryPath: [UUID] = []
    public var isAddSheetPresented = false
    /// A link the Add sheet should open with, if it was handed one rather than found on the
    /// pasteboard. Consumed once.
    public var pendingAddLink: String?
    public var playerID: UUID?
    /// Set only by the `goel://debug/...` links, which exist because `simctl` cannot tap. Reaching
    /// the widget gallery any other way needs four taps no script can perform.
    public var debugScreen: DebugScreen?
    /// Which section of a debug screen to scroll to — `goel://debug/widgets?at=island`. The
    /// gallery is four screens tall and `simctl` cannot scroll it.
    public var debugAnchor: String?

    public enum DebugScreen: String, Identifiable, Hashable, Sendable {
        case widgets, swatches
        public var id: String { rawValue }
    }
    /// Set by T12 so the engine picks up changes without a restart.
    public var tuning: EngineTuning {
        didSet {
            guard tuning != oldValue else { return }
            tuning.save()
            let t = tuning
            Task { await engine.applyTuning(t) }
        }
    }

    public enum Tab: String, Hashable, CaseIterable {
        case downloads, library, remote, settings
        public var title: String {
            switch self {
            case .downloads: "Downloads"
            case .library: "Library"
            case .remote: "Remote"
            case .settings: "Settings"
            }
        }
        public var systemImage: String {
            switch self {
            case .downloads: "arrow.down.circle"
            case .library: "folder"
            case .remote: "desktopcomputer"
            case .settings: "gearshape"
            }
        }
    }

    private let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "app")
    private var pump: Task<Void, Never>?
    /// Last time a speed sample was recorded per download, so the sparkline window stays 60 s.
    private var lastSpeedSample: [UUID: Date] = [:]

    public init(engine: any TransferEngine, store: DownloadStore) {
        self.engine = engine
        self.store = store
        self.tuning = EngineTuning.load()
    }

    /// The real app wiring. `-uiTestingPreviewEngine` selects the frozen fixture engine so
    /// every screenshot is byte-identical run to run.
    public static func makeDefault(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        let wantsPreview = arguments.contains("-uiTestingPreviewEngine")
        let wantsLivePreview = arguments.contains("-uiTestingLiveEngine")

        if wantsPreview || wantsLivePreview {
            let engine = wantsLivePreview ? PreviewTransferEngine.makeLive() : PreviewTransferEngine.makeStatic()
            // A throwaway store so fixtures never overwrite the user's real queue.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("goel-preview-queue.json")
            try? FileManager.default.removeItem(at: tmp)
            let store = DownloadStore(persistenceURL: tmp)
            // Date the fixtures against launch, not against their frozen epoch. Every byte
            // count in `fixtures` is derived from the size and percentage, so `now` only
            // moves `addedAt`/`completedAt` — which is exactly what has to be relative for
            // the queue's "2m ago" to read the way the mockup shows it.
            store.replaceAll(PreviewTransferEngine.fixtures(now: Date()))
            let model = AppModel(engine: engine, store: store)
            model.startEventPump()
            model.applyLaunchRoute(arguments)
            return model
        }

        let store = DownloadStore()
        let engine = URLSessionTransferEngine()
        let model = AppModel(engine: engine, store: store)
        model.startEventPump()
        model.applyLaunchRoute(arguments)
        let t = model.tuning
        Task { await engine.applyTuning(t) }
        model.resumeInterruptedDownloads()
        // Anything the widget extension queued while we were not running (a Pause tapped from
        // the Dynamic Island) is in the App Group command file, not in memory.
        CommandDrain.drain(into: model)
        BackgroundCoordinator.onBackgroundWake = { [weak model] in
            guard let model else { return }
            CommandDrain.drain(into: model)
            ActivityController.shared.backgroundWake(model.store.downloads)
            model.store.persistNow()
        }
        return model
    }

    /// One subscriber for the engine's single multiplexed event stream.
    public func startEventPump() {
        pump?.cancel()
        let events = engine.events
        pump = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: TransferEvent) {
        defer { ActivityController.shared.sync(store.downloads) }
        switch event {
        case let .progress(id, received, total, speed, segments):
            let now = Date()
            let shouldSample = now.timeIntervalSince(lastSpeedSample[id] ?? .distantPast) >= 1
            if shouldSample { lastSpeedSample[id] = now }
            store.apply(id) { d in
                d.receivedBytes = received
                if let total { d.totalBytes = total }
                d.segments = segments
                // One sample per second. The engine emits progress at 10 Hz; sampling every
                // event would make the 60-slot ring buffer span 6 s, and the detail sparkline
                // is drawn as a 60-second window.
                if shouldSample { d.recordSpeedSample(speed) }
                if d.status == .queued || d.status == .probing { d.status = .downloading }
            }
        case let .statusChanged(id, status):
            store.apply(id) { d in
                d.status = status
                if status == .completed { d.completedAt = Date() }
            }
        case let .completed(id, fileURL):
            // `TransferEvent` carries no verification flag by design (it is a value-only
            // contract GoelCore must be able to satisfy later), so ask the engine directly.
            Task { [engine] in
                let verified = await engine.checksumWasVerified(id)
                await MainActor.run { self.store.apply(id) { $0.checksumVerified = verified } }
            }
            store.apply(id) { d in
                d.status = .completed
                d.completedAt = Date()
                d.errorMessage = nil
                d.saveDirectory = fileURL.deletingLastPathComponent().path
                if let total = d.totalBytes { d.receivedBytes = total }
            }
        case let .failed(id, message):
            store.apply(id) { d in
                d.status = .failed
                d.errorMessage = message
            }
        }
    }

    // MARK: - Commands

    public func start(_ download: Download) {
        store.add(download)
        ActivityController.shared.sync(store.downloads)
        Task { [engine] in
            do { try await engine.start(download) } catch {
                await MainActor.run {
                    self.store.apply(download.id) { d in
                        d.status = .failed
                        d.errorMessage = (error as? TransferError)?.userMessage ?? error.localizedDescription
                    }
                }
            }
        }
    }

    public func togglePause(_ id: UUID) {
        guard let d = store[id] else { return }
        switch d.status {
        case .downloading, .probing, .queued, .waitingForWiFi:
            store.apply(id) { $0.status = .paused }
            Task { [engine] in await engine.pause(id) }
        case .paused, .failed:
            store.apply(id) { $0.status = .downloading; $0.errorMessage = nil }
            Task { [engine] in await engine.resume(id) }
        case .verifying, .completed:
            break
        }
    }

    public func remove(_ id: UUID, deleteData: Bool = true) {
        Task { [engine] in await engine.cancel(id, deleteData: deleteData) }
        store.remove(id)
    }

    public func retry(_ id: UUID) {
        guard let d = store[id] else { return }
        store.apply(id) { $0.status = .queued; $0.errorMessage = nil }
        Task { [engine] in try? await engine.start(d) }
    }

    /// After a cold launch, anything the store thinks was mid-flight is not actually running.
    private func resumeInterruptedDownloads() {
        for d in store.downloads where d.status == .downloading || d.status == .probing {
            store.apply(d.id) { $0.status = .paused }
        }
    }

    // MARK: - Scene phase

    /// Foreground ⇄ background is where the handoff (T06, PRD §4.1) happens. Persisting
    /// synchronously on the way out matters: a debounced write that has not fired yet is lost
    /// if iOS suspends us.
    public func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            store.persistNow()
            ActivityController.shared.backgroundWake(store.downloads)
            Task { [engine] in await engine.enterBackground() }
        case .active:
            CommandDrain.drain(into: self)
            ActivityController.shared.sync(store.downloads)
            Task { [engine] in await engine.enterForeground() }
        case .inactive:
            store.persistNow()
        @unknown default:
            break
        }
    }

    // MARK: - Deep links

    /// `-uiTestingRoute goel://…` — the same deep link, but taken at launch instead of through
    /// `openurl`. iOS 26 puts a system "Open in …?" confirmation in front of a scheme opened from
    /// outside the app, and `simctl` cannot tap it, so a scripted screenshot of any screen below
    /// the tab root is otherwise unreachable.
    private func applyLaunchRoute(_ arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "-uiTestingRoute"),
              arguments.index(after: flag) < arguments.endIndex,
              let url = URL(string: arguments[arguments.index(after: flag)])
        else { return }
        handle(url: url)
    }

    /// `goel://download/<uuid>` — from a widget tap (T14) or a Live Activity (T13).
    public func handle(url: URL) {
        guard url.scheme == GoelIdentifiers.urlScheme else { return }
        switch url.host {
        case "download":
            let raw = url.pathComponents.last ?? ""
            if let id = UUID(uuidString: raw), store[id] != nil {
                selectedTab = .downloads
                queuePath = [id]
            } else {
                selectedTab = .downloads
            }
        case "add":
            // `goel://add?url=…` — a link handed over by another app (or by the screenshot
            // harness). Still a prefill, never an auto-queue.
            pendingAddLink = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            selectedTab = .downloads
            isAddSheetPresented = true
        case "library":
            selectedTab = .library
        case "settings":
            selectedTab = .settings
        case "player":
            let raw = url.pathComponents.last ?? ""
            if let id = UUID(uuidString: raw), store[id] != nil { playerID = id }
        case "debug":
            debugAnchor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "at" }?.value
            debugScreen = DebugScreen(rawValue: url.pathComponents.last ?? "")
        #if DEBUG
        case "start":
            // `goel://start?url=…&url=…` — probe and queue, no taps. The screenshot harness has no
            // way to press "Add Download", and a build that has never actually moved a byte in the
            // simulator has not been tested. Debug-only: it queues without asking.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let links = items.filter { $0.name == "url" }.compactMap(\.value)
            // `&play=1` opens the player the moment the transfer starts, which is the only
            // scriptable way to reach play-while-downloading: the id does not exist until now.
            let wantsPlayer = items.contains { $0.name == "play" }
            for link in links {
                guard let target = URL(string: link) else { continue }
                Task { [engine] in
                    let result = try? await engine.probe(target)
                    let download = Download(
                        url: target,
                        filename: result?.filename ?? target.lastPathComponent,
                        saveDirectory: AddSheet.rootFolder,
                        kind: .infer(from: target),
                        status: .queued,
                        totalBytes: result?.totalBytes,
                        isSequential: result?.isStreamable ?? false,
                        supportsResume: result?.supportsResume ?? false,
                        validator: result?.validator
                    )
                    await MainActor.run {
                        self.start(download)
                        if wantsPlayer { self.playerID = download.id }
                    }
                }
            }
        #endif
        default:
            log.warning("Unhandled deep link host: \(url.host ?? "nil", privacy: .public)")
        }
    }
}
