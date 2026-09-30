import XCTest
import GoelCore
@testable import GoelApp

@MainActor
final class FileProgressPublisherTests: XCTestCase {

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private final class Probe {
        var calls: [String] = []
        var existing: Set<String> = []
        func exists(_ path: String) -> Bool { calls.append(path); return existing.contains(path) }
    }

    private func task(id: UUID = UUID(), bytes: Int64 = 10) -> DownloadTask {
        DownloadTask(id: id, source: .url(URL(string: "https://e.test/a.bin")!), name: "a.bin",
                     saveDirectory: "/tmp/goel-fpp", totalBytes: 100, bytesDownloaded: bytes,
                     status: .downloading)
    }

    private func make(_ clock: Clock, _ probe: Probe) -> FileProgressPublisher {
        FileProgressPublisher(now: { clock.now }, fileExists: { probe.exists($0) })
    }

    func testInProgressHTTPIsFoundAtThePartialPath() {
        let clock = Clock(), probe = Probe()
        let t = task()
        probe.existing = [PartialFile.path(for: t.savePath)]
        let publisher = make(clock, probe)
        publisher.update(with: [t]) { _ in }
        XCTAssertEqual(publisher.publishedIDs, [t.id])
        publisher.update(with: []) { _ in }
    }

    func testExistenceIsCachedAndRecheckedOnlyEveryFiveSeconds() {
        let clock = Clock(), probe = Probe()
        let t = task()
        probe.existing = [t.savePath]
        let publisher = make(clock, probe)
        publisher.update(with: [t]) { _ in }
        let afterFirst = probe.calls.count
        for _ in 0..<4 {
            clock.advance(1)
            publisher.update(with: [t]) { _ in }
        }
        XCTAssertEqual(probe.calls.count, afterFirst, "no stat within the 5 s window")
        clock.advance(1.1)
        publisher.update(with: [t]) { _ in }
        XCTAssertGreaterThan(probe.calls.count, afterFirst)
        publisher.update(with: []) { _ in }
    }

    func testByteUpdatesAreRationedToOncePerSecond() {
        let clock = Clock(), probe = Probe()
        let id = UUID()
        probe.existing = [task(id: id).savePath]
        let publisher = make(clock, probe)
        publisher.update(with: [task(id: id, bytes: 10)]) { _ in }
        // Ten pump ticks inside one second: none reaches the Progress object.
        for n in 1...9 {
            clock.advance(0.1)
            publisher.update(with: [task(id: id, bytes: Int64(10 + n))]) { _ in }
        }
        XCTAssertEqual(publisher.completedUnits(for: id), 10)
        clock.advance(0.2)
        publisher.update(with: [task(id: id, bytes: 50)]) { _ in }
        XCTAssertEqual(publisher.completedUnits(for: id), 50)
        publisher.update(with: []) { _ in }
    }

    func testAFinishIsUnpublishedImmediatelyEvenInsideTheThrottleWindow() {
        let clock = Clock(), probe = Probe()
        let t = task()
        probe.existing = [t.savePath]
        let publisher = make(clock, probe)
        publisher.update(with: [t]) { _ in }
        clock.advance(0.1)
        publisher.update(with: []) { _ in }
        XCTAssertTrue(publisher.publishedIDs.isEmpty)
    }

    func testAMissingFileIsNotPublished() {
        let clock = Clock(), probe = Probe()
        let publisher = make(clock, probe)
        publisher.update(with: [task()]) { _ in }
        XCTAssertTrue(publisher.publishedIDs.isEmpty)
    }
}
