import Foundation
import GoelCore

struct SpeedSample: Equatable {
    var down: Double
    var up: Double

    static let zero = SpeedSample(down: 0, up: 0)
}

/// Fixed-capacity FIFO: appending never shifts the whole buffer the way `removeFirst` did.
struct SpeedRing<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    init(capacity: Int, elements: [Element]) {
        self.init(capacity: capacity)
        for element in elements.suffix(self.capacity) { append(element) }
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    var elements: [Element] {
        guard head > 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }
}

/// The 2 Hz speed read-outs and history rings, kept out of `AppViewModel` so a changing number
/// redraws the views that show numbers — not the list, sidebar and menus besides.
@MainActor
final class TelemetryStore: ObservableObject {

    static let historyCap = 120

    /// Menu bar and status bar read this, not the live sums, or the labels flicker.
    @Published private(set) var displayedCombinedSpeed = SpeedSample.zero
    @Published private(set) var displayedTaskSpeed: [DownloadTask.ID: SpeedSample] = [:]
    /// Bumped when a history ring gains a point, so the graphs redraw at the ring's own pace.
    @Published private(set) var historyRevision = 0

    private var taskRings: [DownloadTask.ID: SpeedRing<SpeedSample>] = [:]
    private var sftpRings: [UUID: SpeedRing<Double>] = [:]
    private var globalRing = SpeedRing<SpeedSample>(capacity: TelemetryStore.historyCap)

    func displaySpeed(for task: DownloadTask) -> SpeedSample {
        displayedTaskSpeed[task.id] ?? SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed)
    }

    func taskHistory(_ id: DownloadTask.ID) -> [SpeedSample] { taskRings[id]?.elements ?? [] }
    func sftpHistory(_ id: UUID) -> [Double] { sftpRings[id]?.elements ?? [] }
    var globalHistory: [SpeedSample] { globalRing.elements }
    var trackedTaskCount: Int { taskRings.count }

    /// Idle means nothing moving and every read-out already at rest: the sample can be skipped.
    var isAtRest: Bool {
        displayedCombinedSpeed == .zero && globalRing.elements.allSatisfy { $0 == .zero }
    }

    /// One tick. Rows that left the queue are pruned only when the id set actually shrank,
    /// detected by a count mismatch instead of building a `Set` of every id twice a second.
    func sample(tasks: [DownloadTask], combined: SpeedSample, recordHistory: Bool) {
        if combined != displayedCombinedSpeed { displayedCombinedSpeed = combined }
        var next = displayedTaskSpeed
        var changed = false
        var total = SpeedSample.zero
        for task in tasks {
            let speed = SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed)
            total.down += speed.down
            total.up += speed.up
            if next[task.id] != speed {
                next[task.id] = speed
                changed = true
            }
            guard recordHistory, task.status.isActive else { continue }
            taskRings[task.id, default: SpeedRing(capacity: Self.historyCap)].append(speed)
        }
        if next.count != tasks.count {
            let known = Set(tasks.map(\.id))
            next = next.filter { known.contains($0.key) }
            taskRings = taskRings.filter { known.contains($0.key) }
            changed = true
        }
        if changed { displayedTaskSpeed = next }
        if recordHistory {
            globalRing.append(total)
            historyRevision &+= 1
        }
    }

    /// Only rows that still own a transfer extend their ring: a finished row keeps the shape it
    /// ended on instead of decaying into a flat line. Rings for rows gone from the list are dropped.
    func recordSFTP(_ transfers: [SFTPTransfer]) {
        for transfer in transfers where transfer.occupiesDestination {
            sftpRings[transfer.id, default: SpeedRing(capacity: Self.historyCap)]
                .append(transfer.sampledSpeed ?? 0)
        }
        if sftpRings.count > transfers.count || sftpRings.keys.contains(where: { id in
            !transfers.contains { $0.id == id } }) {
            let known = Set(transfers.map(\.id))
            sftpRings = sftpRings.filter { known.contains($0.key) }
        }
    }

    func restoreTaskHistory(_ saved: [String: [SpeedHistoryPoint]]) {
        for (idString, points) in saved {
            guard let id = UUID(uuidString: idString) else { continue }
            taskRings[id] = SpeedRing(capacity: Self.historyCap,
                                      elements: points.map { SpeedSample(down: $0.down, up: $0.up) })
        }
        historyRevision &+= 1
    }

    /// Unfinished rows only: a finished download's graph has no future to resume into.
    func persistableHistory(for tasks: [DownloadTask]) -> [String: [SpeedHistoryPoint]] {
        var out: [String: [SpeedHistoryPoint]] = [:]
        for task in tasks where !task.status.isTerminal {
            guard let ring = taskRings[task.id], !ring.isEmpty else { continue }
            out[task.id.uuidString] = ring.elements.map { SpeedHistoryPoint(down: $0.down, up: $0.up) }
        }
        return out
    }
}
