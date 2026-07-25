import Foundation
import Observation
import WidgetKit
import os

/// The one place the queue lives.
///
/// Views observe it, the engine mutates it through ``apply(_:_:)``, and it mirrors a small
/// summary into the App Group so the widgets and Live Activity have something to draw.
///
/// Three properties of this class are load-bearing and easy to lose in a refactor:
///
/// 1. **`apply` is O(1).** A running queue mutates several times a second per transfer; a
///    linear scan per tick is visible on a long list.
/// 2. **Disk writes are debounced.** Progress ticks are constant. Writing JSON on each one
///    burns battery and I/O for state nobody will read until relaunch.
/// 3. **Widget reloads are rate limited.** WidgetKit budgets `reloadAllTimelines()`. Calling it
///    on every persist gets the app throttled, and throttled widgets go stale — a worse outcome
///    than updating slowly on purpose.
@MainActor
@Observable
public final class DownloadStore {

    // MARK: - State

    public private(set) var downloads: [Download] = []

    /// `id -> index into downloads`. Kept in step with every mutation below.
    @ObservationIgnored private var index: [UUID: Int] = [:]

    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var lastWidgetReload: Date = .distantPast

    @ObservationIgnored private static let logger = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "DownloadStore")

    /// How long a burst of mutations is coalesced before it reaches disk.
    @ObservationIgnored public static let persistDebounce: Duration = .milliseconds(500)
    /// Floor on the interval between WidgetKit reload requests.
    @ObservationIgnored public static let widgetReloadInterval: TimeInterval = 15

    @ObservationIgnored private static let fileName = "downloads.json"

    // MARK: - Life cycle

    /// - Parameter persistenceURL: `nil` uses the real App Group location. Tests inject a
    ///   temporary file so they never touch — or depend on — the shared container.
    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL ?? SharedSnapshot.containerURL()?
            .appendingPathComponent(Self.fileName, isDirectory: false)
        load()
    }

    deinit {
        // A dropped store must not leave a debounce timer holding it alive.
        persistTask?.cancel()
    }

    // MARK: - Reads

    public subscript(id: UUID) -> Download? {
        guard let i = index[id], downloads.indices.contains(i) else { return nil }
        return downloads[i]
    }

    /// Everything still in the queue: queued, probing, downloading, paused, waiting, verifying.
    /// Terminal rows (completed, failed) belong to the Library, not the queue.
    public var activeDownloads: [Download] {
        downloads.filter { !$0.status.isTerminal }
    }

    /// Finished successfully. Failures are deliberately excluded — they are not library items.
    public var completedDownloads: [Download] {
        downloads.filter { $0.status == .completed }
    }

    // MARK: - Writes

    public func add(_ d: Download) {
        if let i = index[d.id], downloads.indices.contains(i) {
            downloads[i] = d
        } else {
            downloads.append(d)
            index[d.id] = downloads.count - 1
        }
        schedulePersist()
    }

    /// Replaces the download with the same `id`, or inserts it if it is new.
    public func update(_ d: Download) {
        guard let i = index[d.id], downloads.indices.contains(i) else {
            add(d)
            return
        }
        downloads[i] = d
        schedulePersist()
    }

    /// In-place mutation, O(1). The preferred path for progress ticks — it avoids copying the
    /// whole value out and back in on every byte update.
    public func apply(_ id: UUID, _ mutate: (inout Download) -> Void) {
        guard let i = index[id], downloads.indices.contains(i) else { return }
        mutate(&downloads[i])
        // A closure that rewrites `id` would silently desynchronize the index.
        if downloads[i].id != id { reindex() }
        schedulePersist()
    }

    public func remove(_ id: UUID) {
        guard let i = index[id], downloads.indices.contains(i) else { return }
        downloads.remove(at: i)
        reindex()
        schedulePersist()
    }

    public func clearCompleted() {
        let before = downloads.count
        downloads.removeAll { $0.status == .completed }
        guard downloads.count != before else { return }
        reindex()
        schedulePersist()
    }

    public func replaceAll(_ ds: [Download]) {
        downloads = ds
        reindex()
        schedulePersist()
    }

    // MARK: - Snapshot

    /// The widget-facing summary. All arithmetic here is `NaN`-safe: a snapshot with a `NaN`
    /// fraction would fail to encode (`JSONEncoder` rejects non-conforming floats) and the
    /// widgets would silently freeze on whatever they last read.
    public func snapshot() -> SharedSnapshot {
        let live = downloads.filter { !$0.status.isTerminal }

        var receivedSum: Int64 = 0
        var totalSum: Int64 = 0
        for d in live {
            guard let total = d.totalBytes, total > 0 else { continue }
            totalSum += total
            receivedSum += min(max(0, d.receivedBytes), total)
        }
        let aggregate: Double = totalSum > 0 ? Double(receivedSum) / Double(totalSum) : 0

        // Most-complete first so the widget shows what is about to finish.
        let top = live
            .sorted { lhs, rhs in
                if lhs.status.isActive != rhs.status.isActive { return lhs.status.isActive }
                if lhs.fractionComplete != rhs.fractionComplete { return lhs.fractionComplete > rhs.fractionComplete }
                return lhs.addedAt < rhs.addedAt
            }
            .prefix(SharedSnapshot.topLimit)
            .map { d in
                SharedSnapshot.Item(
                    id: d.id.uuidString,
                    filename: d.filename,
                    fraction: d.fractionComplete,
                    speed: d.currentSpeed,
                    kindToken: d.kind.token,
                    isPaused: d.status == .paused || d.status == .waitingForWiFi
                )
            }

        return SharedSnapshot(
            activeCount: downloads.filter { $0.status.isActive }.count,
            totalRemainingBytes: live.reduce(0) { $0 + $1.remainingBytes },
            // Full-queue throughput, so the widget's ETA denominator matches its full-queue
            // remaining-bytes numerator rather than only the top-3 rows the snapshot carries.
            totalSpeed: live.reduce(0) { $0 + max(0, $1.currentSpeed) },
            aggregateFraction: aggregate.isFinite ? min(max(aggregate, 0), 1) : 0,
            updatedAt: Date(),
            top: Array(top)
        )
    }

    // MARK: - Persistence

    /// Synchronous flush. Called by tests and on `scenePhase == .background`, where a debounce
    /// timer is not guaranteed to fire before the process is suspended.
    public func persistNow() {
        persistTask?.cancel()
        persistTask = nil

        if let url = persistenceURL {
            do {
                let data = try Download.makeEncoder().encode(downloads)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                Self.logger.error("Queue persist failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        SharedSnapshot.write(snapshot())
        reloadWidgetsIfAllowed()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: DownloadStore.persistDebounce)
            guard !Task.isCancelled, let self else { return }
            self.persistNow()
        }
    }

    private func reloadWidgetsIfAllowed() {
        let now = Date()
        guard now.timeIntervalSince(lastWidgetReload) >= Self.widgetReloadInterval else { return }
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func load() {
        guard let url = persistenceURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            downloads = try Download.makeDecoder().decode([Download].self, from: data)
            reindex()
        } catch {
            // Corrupt or half-written file. An empty queue is recoverable; a crash on launch
            // is not, and there is no `try!` anywhere on this path for that reason.
            Self.logger.warning("Queue load failed, starting empty: \(error.localizedDescription, privacy: .public)")
            downloads = []
            index = [:]
        }
    }

    private func reindex() {
        index.removeAll(keepingCapacity: true)
        index.reserveCapacity(downloads.count)
        for (i, d) in downloads.enumerated() { index[d.id] = i }
    }
}
