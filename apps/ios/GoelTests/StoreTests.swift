import Foundation
import Testing
@testable import Goel

/// `DownloadStore` is `@MainActor`, so the whole suite is too.
///
/// Every test injects its own temporary file. Nothing here touches the real App Group
/// container, and no two tests can see each other's persisted state.
@Suite("DownloadStore")
@MainActor
struct StoreTests {

    // MARK: - Fixtures

    /// A fresh, unique file path under a directory that does not exist yet — which also
    /// exercises the store's "create the container directory if needed" path.
    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GoelStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("downloads.json", isDirectory: false)
    }

    static func make(
        _ name: String,
        status: Download.Status = .downloading,
        totalBytes: Int64? = 1_000,
        receivedBytes: Int64 = 100,
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Download {
        Download(
            url: URL(string: "https://cdn.example.com/\(name)")!,
            filename: name,
            saveDirectory: "/Downloads",
            kind: .https,
            status: status,
            totalBytes: totalBytes,
            receivedBytes: receivedBytes,
            addedAt: addedAt
        )
    }

    // MARK: - Persistence

    @Test("Write, re-init from disk, identical contents")
    func survivesARelaunch() {
        let url = Self.tempURL()

        let first = DownloadStore(persistenceURL: url)
        #expect(first.downloads.isEmpty)
        let a = Self.make("a.iso")
        let b = Self.make("b.zip", status: .completed, receivedBytes: 1_000)
        first.add(a)
        first.add(b)
        first.persistNow()

        let second = DownloadStore(persistenceURL: url)
        #expect(second.downloads == [a, b])
        #expect(second[a.id] == a)
        #expect(second[b.id] == b)
    }

    @Test("An absent file yields an empty store, not a crash")
    func absentFileIsEmpty() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        #expect(store.downloads.isEmpty)
        #expect(store.activeDownloads.isEmpty)
        #expect(store[UUID()] == nil)
    }

    @Test("A corrupt file yields an empty store, not a crash")
    func corruptFileIsEmpty() throws {
        let url = Self.tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ this is not JSON, it is half a write interrupted by a jetsam kill".utf8)
            .write(to: url)

        let store = DownloadStore(persistenceURL: url)
        #expect(store.downloads.isEmpty)

        // And it must still be usable afterwards — a bad load is not a poisoned store.
        let d = Self.make("recovered.bin")
        store.add(d)
        store.persistNow()
        #expect(DownloadStore(persistenceURL: url).downloads == [d])
    }

    @Test("persistNow flushes immediately rather than waiting out the debounce")
    func persistNowIsSynchronous() {
        let url = Self.tempURL()
        let store = DownloadStore(persistenceURL: url)
        store.add(Self.make("now.bin"))
        store.persistNow()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Mutation

    @Test("apply mutates the stored value in place")
    func applyMutatesInPlace() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        let d = Self.make("a.iso", receivedBytes: 0)
        store.add(d)

        store.apply(d.id) { item in
            item.receivedBytes = 640
            item.status = .paused
            item.recordSpeedSample(2_048)
        }

        #expect(store[d.id]?.receivedBytes == 640)
        #expect(store[d.id]?.status == .paused)
        #expect(store[d.id]?.currentSpeed == 2_048)
        #expect(store.downloads.count == 1)
    }

    @Test("apply on an unknown id is a no-op, not a crash")
    func applyUnknownIDIsANoOp() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        store.add(Self.make("a.iso"))
        store.apply(UUID()) { $0.receivedBytes = 999 }
        #expect(store.downloads.count == 1)
        #expect(store.downloads[0].receivedBytes == 100)
    }

    @Test("The id index stays correct across add, update, and remove")
    func indexStaysCorrect() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        let items = (0..<5).map { Self.make("f\($0).bin") }
        for item in items { store.add(item) }

        store.remove(items[1].id)
        store.remove(items[3].id)
        #expect(store.downloads.count == 3)
        // Every survivor must still be reachable by id — a stale index would return the
        // wrong row here, which is the bug that looks like "the UI updated the wrong item".
        for item in [items[0], items[2], items[4]] {
            #expect(store[item.id] == item)
        }
        #expect(store[items[1].id] == nil)

        var changed = items[4]
        changed.receivedBytes = 777
        store.update(changed)
        #expect(store[items[4].id]?.receivedBytes == 777)
        #expect(store.downloads.count == 3)
    }

    @Test("add with an existing id replaces rather than duplicating")
    func addIsIdempotentByID() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        var d = Self.make("a.iso")
        store.add(d)
        d.receivedBytes = 500
        store.add(d)
        #expect(store.downloads.count == 1)
        #expect(store.downloads[0].receivedBytes == 500)
    }

    @Test("update inserts a download the store has not seen")
    func updateInsertsUnknown() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        let d = Self.make("a.iso")
        store.update(d)
        #expect(store.downloads == [d])
    }

    @Test("clearCompleted removes only completed rows")
    func clearCompletedIsSelective() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        let downloading = Self.make("a.iso", status: .downloading)
        let done = Self.make("b.zip", status: .completed, receivedBytes: 1_000)
        let failed = Self.make("c.dmg", status: .failed)
        let paused = Self.make("d.tar", status: .paused)
        let waiting = Self.make("e.pkg", status: .waitingForWiFi)
        for item in [downloading, done, failed, paused, waiting] { store.add(item) }

        store.clearCompleted()

        #expect(store.downloads.count == 4)
        #expect(store[done.id] == nil)
        // A failure is not a completion — it stays so the user can retry it.
        #expect(store[failed.id] != nil)
        #expect(store[downloading.id] != nil)
        #expect(store[paused.id] != nil)
        #expect(store[waiting.id] != nil)
    }

    @Test("replaceAll swaps the whole queue and rebuilds the index")
    func replaceAllRebuildsIndex() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        store.add(Self.make("old.bin"))
        let fresh = (0..<3).map { Self.make("new\($0).bin") }
        store.replaceAll(fresh)
        #expect(store.downloads == fresh)
        for item in fresh { #expect(store[item.id] == item) }
    }

    @Test("activeDownloads is the queue; completedDownloads is the library")
    func partitions() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        let queued = Self.make("a.iso", status: .queued)
        let downloading = Self.make("b.iso", status: .downloading)
        let done = Self.make("c.zip", status: .completed, receivedBytes: 1_000)
        let failed = Self.make("d.dmg", status: .failed)
        for item in [queued, downloading, done, failed] { store.add(item) }

        #expect(store.activeDownloads.map(\.id) == [queued.id, downloading.id])
        #expect(store.completedDownloads.map(\.id) == [done.id])
    }

    // MARK: - Snapshot

    @Test("snapshot caps top at three no matter how deep the queue is")
    func snapshotCapsTop() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        for i in 0..<8 {
            store.add(Self.make("f\(i).bin", status: .downloading, totalBytes: 1_000, receivedBytes: Int64(i) * 100))
        }
        let snap = store.snapshot()
        #expect(snap.top.count == 3)
        #expect(snap.activeCount == 8)
        // Sorted most-complete-first, so the widget shows what is about to finish.
        #expect(snap.top[0].fraction >= snap.top[1].fraction)
        #expect(snap.top[1].fraction >= snap.top[2].fraction)
        let everyRowIsHTTPS = snap.top.allSatisfy { $0.kindToken == "https" }
        #expect(everyRowIsHTTPS)
    }

    @Test("aggregateFraction is finite even when every length is unknown or zero")
    func aggregateFractionIsNaNSafe() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        store.add(Self.make("a.bin", totalBytes: nil, receivedBytes: 4_096))
        store.add(Self.make("b.bin", totalBytes: 0, receivedBytes: 0))

        let snap = store.snapshot()
        #expect(snap.aggregateFraction.isFinite)
        #expect(!snap.aggregateFraction.isNaN)
        #expect(snap.aggregateFraction == 0)
        #expect(snap.totalRemainingBytes == 0)
    }

    @Test("aggregateFraction weights by bytes, not by row count")
    func aggregateFractionWeightsByBytes() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        store.add(Self.make("big.bin", totalBytes: 1_000, receivedBytes: 500))
        store.add(Self.make("small.bin", totalBytes: 1_000, receivedBytes: 1_000))

        let snap = store.snapshot()
        #expect(snap.aggregateFraction == 0.75)     // 1 500 of 2 000
        #expect(snap.totalRemainingBytes == 500)
    }

    @Test("An empty store snapshots to something a widget can draw")
    func emptySnapshot() {
        let snap = DownloadStore(persistenceURL: Self.tempURL()).snapshot()
        #expect(snap.activeCount == 0)
        #expect(snap.top.isEmpty)
        #expect(snap.aggregateFraction == 0)
        #expect(snap.totalRemainingBytes == 0)
    }

    @Test("Completed and failed rows are excluded from the snapshot")
    func snapshotIgnoresTerminalRows() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        store.add(Self.make("done.zip", status: .completed, totalBytes: 1_000, receivedBytes: 1_000))
        store.add(Self.make("failed.dmg", status: .failed, totalBytes: 1_000, receivedBytes: 10))
        store.add(Self.make("live.iso", status: .downloading, totalBytes: 1_000, receivedBytes: 250))

        let snap = store.snapshot()
        #expect(snap.top.count == 1)
        #expect(snap.top[0].filename == "live.iso")
        #expect(snap.activeCount == 1)
        #expect(snap.aggregateFraction == 0.25)
    }

    @Test("Paused and Wi-Fi-deferred rows are marked paused for the widget")
    func snapshotMarksPaused() {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        store.add(Self.make("p.iso", status: .paused))
        store.add(Self.make("w.iso", status: .waitingForWiFi))
        store.add(Self.make("g.iso", status: .downloading))

        let snap = store.snapshot()
        let byName = Dictionary(uniqueKeysWithValues: snap.top.map { ($0.filename, $0) })
        #expect(byName["p.iso"]?.isPaused == true)
        #expect(byName["w.iso"]?.isPaused == true)
        #expect(byName["g.iso"]?.isPaused == false)
        // Only `downloading` counts as active; paused rows still occupy the queue.
        #expect(snap.activeCount == 1)
    }

    @Test("A snapshot survives its own JSON round trip and truncates top defensively")
    func snapshotEncodes() throws {
        let store = DownloadStore(persistenceURL: Self.tempURL())
        for i in 0..<5 { store.add(Self.make("f\(i).bin", receivedBytes: Int64(i) * 100)) }
        var snap = store.snapshot()
        // Pin the timestamp: `Date()` carries sub-second precision, and this test is about
        // the wire format, not about float printing.
        snap.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(SharedSnapshot.self, from: encoder.encode(snap))
        #expect(decoded == snap)

        // Even a hand-built snapshot cannot hand a widget more than three rows.
        let overfull = SharedSnapshot(
            activeCount: 9,
            totalRemainingBytes: 1,
            aggregateFraction: .nan,
            updatedAt: Date(timeIntervalSince1970: 1),
            top: snap.top + snap.top
        )
        #expect(overfull.top.count == SharedSnapshot.topLimit)
        #expect(overfull.aggregateFraction == 0)   // NaN sanitised at the boundary
        #expect(SharedSnapshot.empty.top.isEmpty)
    }
}
