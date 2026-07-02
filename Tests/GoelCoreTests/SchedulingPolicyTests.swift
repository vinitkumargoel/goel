import XCTest
@testable import GoelCore

/// Boundary tests for the pure queue-promotion decision lifted out of
/// `DownloadManager.schedule()` into ``SchedulingPolicy``. These exercise the
/// subtle parts directly with plain values — priority order, FIFO tie-breaking,
/// the simultaneous-download cap, the metadata-resolution cap (charging only a
/// magnet that still lacks metadata), and the closed-window / no-free-slot gates
/// — instead of driving the full actor with mock engines.
final class SchedulingPolicyTests: XCTestCase {

    private let url = DownloadSource.url(URL(string: "https://example.com/file.bin")!)
    private func magnet() -> DownloadSource { .magnet("magnet:?xt=urn:btih:abcdef0123456789") }

    /// A queued HTTP task by default; `totalBytes: nil` + a magnet source models a
    /// magnet that still needs metadata (`hasMetadata == totalBytes != nil`).
    private func task(
        status: DownloadStatus = .queued,
        priority: FilePriority = .normal,
        addedAt t: TimeInterval = 0,
        source: DownloadSource? = nil,
        totalBytes: Int64? = 1000
    ) -> DownloadTask {
        DownloadTask(source: source ?? url, name: "t", saveDirectory: "/tmp",
                     totalBytes: totalBytes, status: status, priority: priority,
                     addedAt: Date(timeIntervalSince1970: t))
    }

    private func promote(_ tasks: [DownloadTask], running: Set<UUID> = [],
                         maxDownloads: Int = 100, maxMetadata: Int = 100,
                         windowOpen: Bool = true) -> [UUID] {
        SchedulingPolicy.promotions(tasks: tasks, runningSlots: running,
                                    maxSimultaneousDownloads: maxDownloads,
                                    maxMetadataResolutions: maxMetadata,
                                    windowOpen: windowOpen)
    }

    func testPriorityDescThenFIFO() {
        let a = task(priority: .normal, addedAt: 10)   // normal, later
        let b = task(priority: .high,   addedAt: 20)   // high — first regardless of time
        let c = task(priority: .normal, addedAt: 5)    // normal, earliest
        XCTAssertEqual(promote([a, b, c]), [b.id, c.id, a.id],
                       "high first; normals in FIFO (addedAt) order")
    }

    func testSimultaneousCapLimitsCount() {
        let ts = (0..<5).map { task(addedAt: TimeInterval($0)) }
        XCTAssertEqual(promote(ts, maxDownloads: 2), [ts[0].id, ts[1].id],
                       "only 2 slots → earliest two by FIFO")
    }

    func testRunningSlotsConsumeCapacity() {
        let running = task(status: .downloading, addedAt: 0)
        let q1 = task(addedAt: 1); let q2 = task(addedAt: 2)
        XCTAssertEqual(promote([running, q1, q2], running: [running.id], maxDownloads: 2),
                       [q1.id], "1 of 2 slots already used → exactly 1 promotion")
    }

    func testClosedWindowPromotesNothing() {
        XCTAssertEqual(promote([task()], windowOpen: false), [])
    }

    func testNoFreeSlots() {
        let r = task(status: .downloading)
        XCTAssertEqual(promote([r, task()], running: [r.id], maxDownloads: 1), [])
    }

    func testOnlyQueuedEligible() {
        let downloading = task(status: .downloading, addedAt: 0)
        let paused = task(status: .paused, addedAt: 1)
        let queued = task(status: .queued, addedAt: 2)
        XCTAssertEqual(promote([downloading, paused, queued]), [queued.id])
    }

    func testMetadataCapHoldsBackExtraMagnets() {
        let m1 = task(priority: .high, addedAt: 1, source: magnet(), totalBytes: nil)
        let m2 = task(priority: .high, addedAt: 2, source: magnet(), totalBytes: nil)
        let http = task(priority: .low, addedAt: 3)  // regular download, never charged
        let out = promote([m1, m2, http], maxMetadata: 1)
        XCTAssertEqual(out, [m1.id, http.id],
                       "one metadata slot → m1 resolves, m2 held back; the HTTP task promotes freely")
        XCTAssertFalse(out.contains(m2.id))
    }

    func testResolvedMagnetNotChargedAgainstMetadataCap() {
        // Two magnets that already HAVE metadata (resumed) — neither occupies a
        // metadata slot, so both promote even though maxMetadata is 1.
        let m1 = task(addedAt: 1, source: magnet(), totalBytes: 500)
        let m2 = task(addedAt: 2, source: magnet(), totalBytes: 500)
        XCTAssertEqual(promote([m1, m2], maxMetadata: 1), [m1.id, m2.id],
                       "already-resolved magnets aren't charged against the metadata cap")
    }

    func testInFlightMetadataResolutionCountsAgainstCap() {
        let resolving = task(status: .requestingMetadata, addedAt: 0, source: magnet(), totalBytes: nil)
        let queuedMagnet = task(status: .queued, addedAt: 1, source: magnet(), totalBytes: nil)
        XCTAssertEqual(promote([resolving, queuedMagnet], running: [resolving.id], maxMetadata: 1),
                       [], "the single metadata slot is already taken by the in-flight resolution")
    }

    func testZeroCapsMeanUnlimited() {
        let ts = (0..<4).map { task(addedAt: TimeInterval($0)) }
        XCTAssertEqual(promote(ts, maxDownloads: 0, maxMetadata: 0).count, 4,
                       "0 caps are treated as unlimited")
    }
}
