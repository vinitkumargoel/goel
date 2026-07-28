import XCTest
@testable import GoelCore

final class MidflightUpgradeTests: XCTestCase {

    private typealias R = SegmentedTransfer.Range64

    private let MiB: Int64 = 1024 * 1024

    private func assertTiles(_ layout: (ranges: [R], restored: [Int: Int64]),
                             total: Int64,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard !layout.ranges.isEmpty else {
            XCTFail("layout has no ranges for total \(total)", file: file, line: line)
            return
        }
        XCTAssertEqual(layout.ranges.first?.start, 0, "first range must start at 0", file: file, line: line)
        XCTAssertEqual(layout.ranges.last?.end, total - 1, "last range must end at total-1", file: file, line: line)
        for (prev, next) in zip(layout.ranges, layout.ranges.dropFirst()) {
            XCTAssertEqual(next.start, prev.end + 1,
                           "ranges must be contiguous with no gap or overlap", file: file, line: line)
        }
        for (index, done) in layout.restored {
            guard layout.ranges.indices.contains(index) else {
                XCTFail("restored key \(index) has no matching range", file: file, line: line)
                continue
            }
            let r = layout.ranges[index]
            XCTAssertGreaterThanOrEqual(done, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(done, r.end - r.start + 1,
                                     "restored bytes must fit their segment", file: file, line: line)
        }
    }

    func testShouldAttemptUpgradeRequiresSizeNoRangesAndValidator() {
        XCTAssertFalse(SegmentedTransfer.shouldAttemptUpgrade(
            totalBytes: nil, acceptsRanges: false, etag: "\"v1\"", lastModified: nil))
        XCTAssertFalse(SegmentedTransfer.shouldAttemptUpgrade(
            totalBytes: 8 * MiB - 1, acceptsRanges: false, etag: "\"v1\"", lastModified: nil))
        XCTAssertFalse(SegmentedTransfer.shouldAttemptUpgrade(
            totalBytes: 8 * MiB, acceptsRanges: true, etag: "\"v1\"", lastModified: nil))
        // No validator: the streamed prefix cannot be proven identical to ranged bytes, so the upgrade must never fire.
        XCTAssertFalse(SegmentedTransfer.shouldAttemptUpgrade(
            totalBytes: 8 * MiB, acceptsRanges: false, etag: nil, lastModified: nil))

        XCTAssertTrue(SegmentedTransfer.shouldAttemptUpgrade(
            totalBytes: 8 * MiB, acceptsRanges: false, etag: "\"v1\"", lastModified: nil))
        XCTAssertTrue(SegmentedTransfer.shouldAttemptUpgrade(
            totalBytes: 8 * MiB, acceptsRanges: false, etag: nil,
            lastModified: "Tue, 01 Jul 2025 00:00:00 GMT"))
    }

    func testUpgradedLayoutPrefixPlusRemainderSplit() {
        let total = 100 * MiB, written = 10 * MiB
        let layout = SegmentedTransfer.upgradedLayout(total: total, written: written, connections: 4)

        XCTAssertEqual(layout.ranges.count, 5, "completed prefix + 4 tail segments")
        XCTAssertEqual(layout.ranges[0].start, 0)
        XCTAssertEqual(layout.ranges[0].end, written - 1, "prefix covers exactly the flushed bytes")
        XCTAssertEqual(layout.restored, [0: written], "only the prefix is restored")
        XCTAssertEqual(layout.ranges[1].start, written, "first tail resumes where the stream stopped")
        assertTiles(layout, total: total)
    }

    func testUpgradedLayoutOmitsPrefixWhenNothingFlushed() {
        let total = 8 * MiB
        let layout = SegmentedTransfer.upgradedLayout(total: total, written: 0, connections: 4)

        XCTAssertEqual(layout.ranges.count, 4, "no prefix segment when nothing was flushed")
        XCTAssertTrue(layout.restored.isEmpty)
        assertTiles(layout, total: total)
    }

    func testUpgradedLayoutSingleConnection() {
        let total = 20 * MiB, written = 5 * MiB
        let layout = SegmentedTransfer.upgradedLayout(total: total, written: written, connections: 1)

        XCTAssertEqual(layout.ranges.count, 2, "prefix + one tail")
        XCTAssertEqual(layout.ranges[1].start, written)
        XCTAssertEqual(layout.ranges[1].end, total - 1)
        XCTAssertEqual(layout.restored, [0: written])
        assertTiles(layout, total: total)
    }

    func testUpgradedLayoutEightConnectionsTileRemainder() {
        let total = 64 * MiB, written = 3 * MiB
        let layout = SegmentedTransfer.upgradedLayout(total: total, written: written, connections: 8)

        XCTAssertEqual(layout.ranges.count, 9, "prefix + 8 tail segments")
        XCTAssertEqual(layout.restored, [0: written])
        for tail in layout.ranges.dropFirst() {
            XCTAssertGreaterThanOrEqual(tail.end - tail.start + 1, 64 * 1024)
        }
        assertTiles(layout, total: total)
    }

    func testUpgradedLayoutClampsByMinSegment() {
        let written = 10 * MiB
        let total = written + 100 * 1024

        let single = SegmentedTransfer.upgradedLayout(total: total, written: written, connections: 8)
        XCTAssertEqual(single.ranges.count, 1 + 2)
        assertTiles(single, total: total)

        let multi = SegmentedTransfer.upgradedLayout(total: total, written: written,
                                                     connections: 8, minSegment: 32 * 1024)
        XCTAssertEqual(multi.ranges.count, 1 + 4)
        assertTiles(multi, total: total)
    }

    func testUpgradedLayoutRemainderSmallerThanFloor() {
        let total = 10 * MiB, written = 10 * MiB - 1000
        let layout = SegmentedTransfer.upgradedLayout(total: total, written: written, connections: 8)

        XCTAssertEqual(layout.ranges.count, 2, "sub-floor remainder must stay a single tail")
        XCTAssertEqual(layout.ranges[1].start, written)
        XCTAssertEqual(layout.ranges[1].end, total - 1)
        assertTiles(layout, total: total)
    }

    func testUpgradedLayoutZeroRemainder() {
        let total = 16 * MiB
        let layout = SegmentedTransfer.upgradedLayout(total: total, written: total, connections: 4)

        XCTAssertEqual(layout.ranges.count, 1)
        XCTAssertEqual(layout.ranges[0].start, 0)
        XCTAssertEqual(layout.ranges[0].end, total - 1)
        XCTAssertEqual(layout.restored, [0: total])
        assertTiles(layout, total: total)
    }

    func testUpgradedLayoutFloorsConnectionsAtOne() {
        let total = 9 * MiB
        let layout = SegmentedTransfer.upgradedLayout(total: total, written: 0, connections: 0)
        XCTAssertEqual(layout.ranges.count, 1)
        assertTiles(layout, total: total)
    }

    func testUpgradeSignalTripIsSticky() {
        let signal = UpgradeSignal()
        XCTAssertFalse(signal.isTripped)
        signal.trip()
        XCTAssertTrue(signal.isTripped)
        signal.trip()
        XCTAssertTrue(signal.isTripped, "a tripped signal never resets")
    }

    func testExtraGrantCounterAccumulatesAndIgnoresNonPositive() {
        let counter = ExtraGrantCounter()
        XCTAssertEqual(counter.total, 0)
        counter.add(3)
        counter.add(0)
        counter.add(-5)
        counter.add(2)
        XCTAssertEqual(counter.total, 5, "only positive grants count toward the balancing release")
    }

    func testGrantExtraConnectionsClampsToHostRoomAndCharges() async {
        let config = URLSessionConfiguration.ephemeral
        let engine = HTTPEngine(configuration: config, profile: .medium)

        let first = await engine.grantExtraConnections(host: "h.example", wanted: 100)
        XCTAssertEqual(first, 8, "grant clamps to the per-server budget, no floor-of-1")

        let second = await engine.grantExtraConnections(host: "h.example", wanted: 3)
        XCTAssertEqual(second, 0, "a saturated host budget grants zero, not one")

        let charged = await engine.connectionBudget.totalConnections
        XCTAssertEqual(charged, first, "every granted connection must be charged")

        await engine.releaseConnections(host: "h.example", count: first)
        let drained = await engine.connectionBudget.totalConnections
        XCTAssertEqual(drained, 0, "the budget must balance to zero after release")
    }

    func testGrantExtraConnectionsRefusesNonPositiveWant() async {
        let config = URLSessionConfiguration.ephemeral
        let engine = HTTPEngine(configuration: config, profile: .medium)
        let granted = await engine.grantExtraConnections(host: "h.example", wanted: 0)
        XCTAssertEqual(granted, 0)
        let negative = await engine.grantExtraConnections(host: "h.example", wanted: -4)
        XCTAssertEqual(negative, 0)
        let charged = await engine.connectionBudget.totalConnections
        XCTAssertEqual(charged, 0, "refused wants must charge nothing")
    }
}

final class MidflightUpgradeBehaviourTests: XCTestCase {

    private var tempDir: URL!

    private let MiB = 1024 * 1024
    private let tripSettleNanos: UInt64 = 150_000_000

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        StubURLProtocol.forceNext429s(0)
        StubURLProtocol.resetSeenUserAgents()
    }

    override func tearDown() {
        // Never leave a parked body behind: a stub thread spinning on a hold that nothing releases would outlive the test.
        StubURLProtocol.releaseUnrangedBody()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func deterministicData(_ count: Int) -> Data {
        var period = Data(capacity: 256)
        for i in 0..<256 { period.append(UInt8((i * 31 + 7) & 0xFF)) }
        var data = Data(capacity: count)
        while data.count + 256 <= count { data.append(period) }
        if data.count < count { data.append(period.prefix(count - data.count)) }
        return data
    }

    /// A nil `requestExtraConnections` disables the upgrade, so every plan under test must be handed a grant channel.
    private func upgradablePlan(name: String, totalBytes: Int, etag: String?,
                                grants: GrantLog?) -> TransferPlan {
        var plan = TransferPlan(
            url: URL(string: "https://example.test/\(name)")!,
            destination: tempDir.appendingPathComponent(name),
            totalBytes: Int64(totalBytes),
            acceptsRanges: false,
            etag: etag,
            lastModified: nil,
            existingResume: nil,
            segmentCount: 8,
            session: makeSession(),
            settings: RequestSettings(userAgent: "GoelTest/1.0", maxAttempts: 10, retryInterval: 0),
            maxBytesPerSecond: 0,
            flushSize: 64 * 1024
        )
        plan.upgradeProbing = UpgradeProbing(initialDelay: 0.05, interval: 0.05, maxAttempts: 60)
        plan.requestExtraConnections = grants?.closure
        return plan
    }

    private func midpointProbe(total: Int) -> String {
        let m = max(0, Int64(total) / 2)
        return "bytes=\(m)-\(m)"
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes?[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Callers must ALWAYS release the parked body afterwards, so a timeout fails the assertion without hanging the transfer.
    private func waitUntil(_ label: String, timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(label)", file: file, line: line)
    }

    private func start(_ transfer: SegmentedTransfer) -> (runner: Task<TransferOutcome, Error>, ticks: TickLog) {
        let ticks = TickLog()
        let stream = transfer.progress
        let consumer = Task { for await update in stream { ticks.add(update) } }
        ticks.consumer = consumer
        return (Task { try await transfer.run() }, ticks)
    }

    func testMidflightUpgradeCompletesSegmentedWithPrefixIntact() async throws {
        let total = 16 * MiB
        let payload = deterministicData(total)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v1\"", chunkSize: 64 * 1024, chunkDelayMicros: 500,
            holdUnrangedBodyAt: 1 * MiB
        ))
        let grants = GrantLog(grant: 3)
        let plan = upgradablePlan(name: "upgrade.bin", totalBytes: total, etag: "\"v1\"", grants: grants)
        let transfer = SegmentedTransfer(plan: plan)
        let (runner, ticks) = start(transfer)

        await waitUntil("the midpoint range probe") {
            StubURLProtocol.seenRangeHeaders().contains(self.midpointProbe(total: total))
        }
        try await Task.sleep(nanoseconds: tripSettleNanos)
        StubURLProtocol.releaseUnrangedBody()

        let outcome = try await runner.value
        await ticks.finish()

        XCTAssertEqual(grants.callCount, 1, "exactly one budget request per upgrade")
        XCTAssertGreaterThanOrEqual(grants.wanted.first ?? 0, 1,
                                    "the upgrade must ask for at least one extra connection")
        XCTAssertGreaterThan(outcome.usedSegments, 1,
                             "the upgraded phase runs the prefix segment plus a cut tail")
        XCTAssertEqual(outcome.bytesWritten, Int64(total))

        let resumeData = try XCTUnwrap(outcome.resumeData,
                                       "an upgraded transfer is resumable — single-stream never was")
        let cursor = try JSONDecoder().decode(SegmentedTransfer.ResumeCursor.self, from: resumeData)
        XCTAssertEqual(cursor.ranges.first?.start, 0)
        XCTAssertGreaterThan(cursor.completed.first ?? 0, 0,
                             "the streamed prefix is carried into the cursor, not refetched")

        XCTAssertGreaterThan(ticks.maxConnections, 1,
                             "the segmented phase must report a wider fan-out than the stream did")
        XCTAssertTrue(ticks.isMonotonic,
                      "progress must never go backwards across the single→segmented handover")

        let written = try Data(contentsOf: plan.destination)
        XCTAssertEqual(written, payload, "the stitched file must equal the source bytes end-to-end")
    }

    func testUpgradeSkippedWithoutValidator() async throws {
        let total = 16 * MiB
        let payload = deterministicData(total)
        // No hold: the gate refuses, so nothing would ever release a parked body.
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: nil, chunkSize: 64 * 1024, chunkDelayMicros: 0
        ))
        let grants = GrantLog(grant: 3)
        let plan = upgradablePlan(name: "novalidator.bin", totalBytes: total, etag: nil, grants: grants)
        let transfer = SegmentedTransfer(plan: plan)
        let (runner, ticks) = start(transfer)

        let outcome = try await runner.value
        await ticks.finish()

        XCTAssertEqual(grants.callCount, 0, "no validator ⇒ no upgrade ⇒ no budget request")
        XCTAssertEqual(outcome.usedSegments, 1, "the transfer stays a single stream")
        XCTAssertNil(outcome.resumeData)
        XCTAssertTrue(StubURLProtocol.seenRangeHeaders().isEmpty,
                      "the prober must never even be spawned without a validator")
        XCTAssertEqual(try Data(contentsOf: plan.destination), payload)
    }

    func testUpgradeRejectedWhenProbeValidatorsChanged() async throws {
        let total = 8 * MiB
        let payload = deterministicData(total)
        // Ranged responses carry "v2" and the UNRANGED stream the plan's "v1", so only `probeMidpointRange`'s validator can refuse.
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v2\"", chunkSize: 64 * 1024, chunkDelayMicros: 500,
            holdUnrangedBodyAt: 1 * MiB,
            unrangedETagOverride: "\"v1\""
        ))
        let grants = GrantLog(grant: 3)
        let plan = upgradablePlan(name: "probemismatch.bin", totalBytes: total, etag: "\"v1\"", grants: grants)
        let transfer = SegmentedTransfer(plan: plan)
        let (runner, ticks) = start(transfer)

        await waitUntil("the midpoint range probe") {
            StubURLProtocol.seenRangeHeaders().contains(self.midpointProbe(total: total))
        }
        try await Task.sleep(nanoseconds: tripSettleNanos)
        StubURLProtocol.releaseUnrangedBody()

        let outcome = try await runner.value
        await ticks.finish()

        XCTAssertEqual(grants.callCount, 0, "a 206 from a different entity must not trip the upgrade")
        XCTAssertEqual(outcome.usedSegments, 1)
        XCTAssertNil(outcome.resumeData)
        XCTAssertEqual(try Data(contentsOf: plan.destination), payload,
                       "the refused upgrade leaves the single stream completing untouched")
    }

    func testUpgradeDisabledWhenStreamEntityDiffers() async throws {
        let total = 8 * MiB
        let payload = deterministicData(total)
        // The probe sees "v1" and DOES trip, but the streaming 200 is "v2" — the prefix on disk can't be proven to be the probed entity, so the pump is never armed.
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v1\"", chunkSize: 64 * 1024, chunkDelayMicros: 500,
            holdUnrangedBodyAt: 1 * MiB,
            unrangedETagOverride: "\"v2\""
        ))
        let grants = GrantLog(grant: 3)
        let plan = upgradablePlan(name: "streammismatch.bin", totalBytes: total, etag: "\"v1\"", grants: grants)
        let transfer = SegmentedTransfer(plan: plan)
        let (runner, ticks) = start(transfer)

        await waitUntil("the midpoint range probe") {
            StubURLProtocol.seenRangeHeaders().contains(self.midpointProbe(total: total))
        }
        try await Task.sleep(nanoseconds: tripSettleNanos)
        StubURLProtocol.releaseUnrangedBody()

        let outcome = try await runner.value
        await ticks.finish()

        XCTAssertTrue(StubURLProtocol.seenRangeHeaders().contains(midpointProbe(total: total)),
                      "the probe must really have fired — otherwise this proves nothing")
        XCTAssertEqual(grants.callCount, 0,
                       "a tripped signal must not upgrade when the streamed entity differs")
        XCTAssertEqual(outcome.usedSegments, 1)
        XCTAssertEqual(try Data(contentsOf: plan.destination), payload)
    }

    func testUpgradeOvershootFailsInsteadOfCompleting() async throws {
        let total = 9 * MiB
        let probed = deterministicData(total)
        let streamed = deterministicData(12 * MiB)
        // Ranges start UNSUPPORTED so the prober cannot trip before the stream overshoots; the flip below arms it, and by then > `total` bytes are provably on disk.
        StubURLProtocol.set(.init(
            data: probed, supportsRanges: false, sendContentLength: true,
            etag: "\"v1\"", chunkSize: 64 * 1024, chunkDelayMicros: 2000,
            holdUnrangedBodyAt: 10 * MiB,
            unrangedData: streamed
        ))
        let grants = GrantLog(grant: 3)
        let plan = upgradablePlan(name: "overshoot.bin", totalBytes: total, etag: "\"v1\"", grants: grants)
        let transfer = SegmentedTransfer(plan: plan)
        let (runner, ticks) = start(transfer)

        await waitUntil("10 MiB of the oversized stream to be flushed") {
            self.fileSize(plan.destination) >= Int64(10 * self.MiB)
        }
        // `set` also clears the recorded headers, so the probe observed below is unambiguously a post-flip one.
        StubURLProtocol.set(.init(
            data: probed, supportsRanges: true, sendContentLength: true,
            etag: "\"v1\"", chunkSize: 64 * 1024, chunkDelayMicros: 2000,
            holdUnrangedBodyAt: 10 * MiB,
            unrangedData: streamed
        ))
        await waitUntil("a midpoint probe answered with a 206") {
            StubURLProtocol.seenRangeHeaders().contains(self.midpointProbe(total: total))
        }
        try await Task.sleep(nanoseconds: tripSettleNanos)
        StubURLProtocol.releaseUnrangedBody()

        var thrown: Error?
        do { _ = try await runner.value } catch { thrown = error }
        await ticks.finish()

        let error = try XCTUnwrap(thrown, "an overshooting stream must never be reported as completed")
        guard case DownloadError.network(let message)? = error as? DownloadError else {
            return XCTFail("expected DownloadError.network, got \(error)")
        }
        XCTAssertTrue(message.contains("wrote"), "expected the completeness message, got: \(message)")
        // The number pins WHICH guard fired: `upgradeToSegmented`'s written > total check, not `runSingle`'s end-of-stream net (which would report the full 12 MiB).
        XCTAssertTrue(message.contains("of \(Int64(total)) bytes"), message)
        XCTAssertFalse(message.contains("wrote \(Int64(12 * MiB))"),
                       "the failure must come from the upgrade guard, before the stream ended")
        XCTAssertEqual(grants.callCount, 0, "the overshoot throw precedes the budget grant")
    }

    func testUpgradedPhaseRetriesRangedTwoHundredFlapback() async throws {
        let total = 8 * MiB
        let payload = deterministicData(total)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v1\"", chunkSize: 64 * 1024, chunkDelayMicros: 500,
            holdUnrangedBodyAt: 1 * MiB
        ))
        // Single-byte ranges are exempt from the forced 200, so the midpoint probe still trips.
        StubURLProtocol.force200ForMultiByteRangedGETs(2)

        let grants = GrantLog(grant: 3)
        let plan = upgradablePlan(name: "flapback.bin", totalBytes: total, etag: "\"v1\"", grants: grants)
        let transfer = SegmentedTransfer(plan: plan)
        let (runner, ticks) = start(transfer)

        await waitUntil("the midpoint range probe") {
            StubURLProtocol.seenRangeHeaders().contains(self.midpointProbe(total: total))
        }
        try await Task.sleep(nanoseconds: tripSettleNanos)
        StubURLProtocol.releaseUnrangedBody()

        let outcome = try await runner.value
        await ticks.finish()

        XCTAssertEqual(grants.callCount, 1)
        XCTAssertGreaterThan(outcome.usedSegments, 1)
        XCTAssertEqual(outcome.bytesWritten, Int64(total),
                       "a ranged 200 in the upgraded phase is retried, not fatal")
        XCTAssertEqual(try Data(contentsOf: plan.destination), payload)
        let multiByte = StubURLProtocol.seenRangeHeaders().filter { header in
            guard let (start, end) = StubURLProtocol.parseRange(header, total: total) else { return false }
            return end > start
        }
        XCTAssertGreaterThan(multiByte.count, outcome.usedSegments - 1,
                             "each forced 200 must have produced an extra attempt")
    }

    func testConnectionBudgetBalancesToZeroAfterMidflightUpgrade() async throws {
        let total = 8 * MiB
        let payload = deterministicData(total)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v1\"", chunkSize: 64 * 1024, chunkDelayMicros: 500,
            holdUnrangedBodyAt: 1 * MiB
        ))
        let engine = HTTPEngine(configuration: URLSessionConfiguration.ephemeral, profile: .medium)
        let host = "example.test"
        let extraGrants = ExtraGrantCounter()

        var plan = upgradablePlan(name: "budget.bin", totalBytes: total, etag: "\"v1\"", grants: nil)
        plan.requestExtraConnections = { [weak engine] wanted in
            guard let engine, wanted > 0 else { return 0 }
            let granted = await engine.grantExtraConnections(host: host, wanted: wanted)
            extraGrants.add(granted)
            return granted
        }

        let transfer = SegmentedTransfer(plan: plan)
        let reserved = transfer.connectionCount
        XCTAssertEqual(reserved, 1, "a single-stream transfer reserves one connection")
        await engine.reserveConnections(host: host, count: reserved)

        let (runner, ticks) = start(transfer)
        await waitUntil("the midpoint range probe") {
            StubURLProtocol.seenRangeHeaders().contains(self.midpointProbe(total: total))
        }
        try await Task.sleep(nanoseconds: tripSettleNanos)
        StubURLProtocol.releaseUnrangedBody()

        let outcome = try await runner.value
        await ticks.finish()

        XCTAssertGreaterThan(outcome.usedSegments, 1, "the transfer must actually have upgraded")
        XCTAssertGreaterThan(extraGrants.total, 0, "the Medium profile has room for real extras")
        let charged = await engine.connectionBudget.totalConnections
        XCTAssertEqual(charged, reserved + extraGrants.total,
                       "every mid-flight grant must be charged, on top of the initial reservation")

        await engine.releaseConnections(host: host, count: reserved + extraGrants.total)
        let drained = await engine.connectionBudget.totalConnections
        XCTAssertEqual(drained, 0, "the budget must balance to zero after an upgraded download ends")
        let perHost = await engine.connectionBudget.hostInUse(host)
        XCTAssertEqual(perHost, 0, "and the per-host ledger must drain with it")
        XCTAssertEqual(try Data(contentsOf: plan.destination), payload)
    }
}

private final class GrantLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Int] = []
    private let grant: Int

    init(grant: Int) { self.grant = grant }

    var wanted: [Int] { lock.lock(); defer { lock.unlock() }; return calls }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }

    private func record(_ wanted: Int) { lock.lock(); calls.append(wanted); lock.unlock() }

    var closure: @Sendable (Int) async -> Int {
        { [self] wanted in
            record(wanted)
            return max(0, min(grant, wanted))
        }
    }
}

private final class TickLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [TransferProgress] = []
    var consumer: Task<Void, Never>?

    func add(_ tick: TransferProgress) { lock.lock(); ticks.append(tick); lock.unlock() }

    func finish() async { await consumer?.value }

    var maxConnections: Int {
        lock.lock(); defer { lock.unlock() }
        return ticks.map(\.connectionCount).max() ?? 0
    }

    var isMonotonic: Bool {
        lock.lock(); defer { lock.unlock() }
        let bytes = ticks.map(\.bytesDownloaded)
        return zip(bytes, bytes.dropFirst()).allSatisfy { $0 <= $1 }
    }
}
