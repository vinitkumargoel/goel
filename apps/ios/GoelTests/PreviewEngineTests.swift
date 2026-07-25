import Foundation
import Testing

@testable import Goel

/// These tests are the contract between `visual.html` and every screenshot task that follows.
/// If one of them fails, a frame in the mockup no longer matches what the app will draw — fix
/// the fixture, not the test.
@Suite("PreviewTransferEngine")
struct PreviewEngineTests {

    // The reference instant every fixture is dated against. Fixed, never `Date()`.
    private static let now = Date(timeIntervalSince1970: 1_784_000_000)

    private func fixture(_ filename: String) throws -> Download {
        let all = PreviewTransferEngine.fixtures(now: Self.now)
        return try #require(
            all.first { $0.filename == filename },
            "no fixture named \(filename)"
        )
    }

    // MARK: - The queue, exactly as visual.html frame 1 draws it

    @Test("fixtures() returns the five downloads from visual.html in queue order")
    func queueOrder() {
        let filenames = PreviewTransferEngine.fixtures(now: Self.now).map(\.filename)
        #expect(filenames == [
            "ubuntu-24.04.1-desktop-amd64.iso",
            "nas-backup-2026-07-14.tar.zst",
            "keynote-2026-4k-hdr.mp4",
            "dataset-imagenet-subset.tar",
            "Blender-4.2-macOS-arm64.dmg",
        ])
    }

    @Test("fixtures() is pure — the same reference date yields an identical array")
    func determinism() {
        #expect(PreviewTransferEngine.fixtures(now: Self.now)
                == PreviewTransferEngine.fixtures(now: Self.now))
    }

    // MARK: - Ubuntu: the row every later task is measured against

    @Test("the ubuntu row is exactly 63 percent complete")
    func ubuntuIsSixtyThreePercent() throws {
        let ubuntu = try fixture("ubuntu-24.04.1-desktop-amd64.iso")
        #expect(abs(ubuntu.fractionComplete - 0.63) < 0.001)
        // The mockup prints "63" as an integer; assert the rounded value the UI will show.
        #expect((ubuntu.fractionComplete * 1000).rounded() == 630)
        #expect(ubuntu.totalBytes == 5_730_000_000)      // "Total 5.73 GB"
        #expect(ubuntu.receivedBytes == 3_609_902_000)   // "Downloaded 3.61 GB"
        #expect(ubuntu.status == .downloading)
        #expect(ubuntu.supportsResume)                   // "Resume — Supported"
        #expect(ubuntu.sourceHost == "releases.ubuntu.com")
    }

    @Test("the ubuntu row reports six segments at 100/78/64/57/41/22 percent")
    func ubuntuSegments() throws {
        let ubuntu = try fixture("ubuntu-24.04.1-desktop-amd64.iso")
        #expect(ubuntu.segments.count == 6)

        let hundredths = ubuntu.segments.map { ($0.fraction * 100).rounded() / 100 }
        #expect(hundredths == [1.00, 0.78, 0.64, 0.57, 0.41, 0.22])

        // The first is finished and drawn green; the other five are live.
        #expect(ubuntu.segments.first?.isComplete == true)
        #expect(ubuntu.segments.first?.isActive == false)
        #expect(ubuntu.segments.dropFirst().allSatisfy { $0.isActive })

        // Segments tile the file with no gaps and no overlap.
        #expect(ubuntu.segments.reduce(Int64(0)) { $0 + $1.totalBytes } == 5_730_000_000)
        #expect(ubuntu.segments.first?.range.lowerBound == 0)
        #expect(ubuntu.segments.last?.range.upperBound == 5_729_999_999)
        for (previous, next) in zip(ubuntu.segments, ubuntu.segments.dropFirst()) {
            #expect(previous.range.upperBound + 1 == next.range.lowerBound)
        }

        // The segment received bytes are the source of truth for the total.
        #expect(ubuntu.segments.reduce(Int64(0)) { $0 + $1.receivedBytes } == ubuntu.receivedBytes)
    }

    @Test("the ubuntu row reads 48.2 MB/s and 44 s left, like every frame in the mockup")
    func ubuntuSpeedAndETA() throws {
        let ubuntu = try fixture("ubuntu-24.04.1-desktop-amd64.iso")
        // `currentSpeed` is the mean of the last three samples — the curve is built to land there.
        #expect(abs(ubuntu.currentSpeed - 48_200_000) < 1_000)
        #expect(ubuntu.speedSamples.count == Download.speedSampleLimit)
        // A flat line would make T08's sparkline pointless; require real variation.
        let low = try #require(ubuntu.speedSamples.min())
        let high = try #require(ubuntu.speedSamples.max())
        #expect(high - low > 0.1 * 48_200_000)

        let eta = try #require(ubuntu.eta)
        #expect((eta).rounded() == 44)
        #expect(ubuntu.remainingBytes == 2_120_098_000)  // "2.1 GB left"
    }

    // MARK: - The other four rows

    @Test("the remaining four rows match their percentages, sizes and kinds")
    func otherRows() throws {
        let nas = try fixture("nas-backup-2026-07-14.tar.zst")
        #expect(nas.totalBytes == 12_600_000_000)
        #expect(abs(nas.fractionComplete - 0.31) < 0.001)
        #expect(nas.kind == .sftp)
        #expect(abs(nas.currentSpeed - 12_400_000) < 1_000)

        let keynote = try fixture("keynote-2026-4k-hdr.mp4")
        #expect(keynote.totalBytes == 2_100_000_000)
        #expect(abs(keynote.fractionComplete - 0.23) < 0.001)
        #expect(keynote.isSequential)
        #expect(keynote.segments.count == 1)  // sequential rules out parallel ranges

        let dataset = try fixture("dataset-imagenet-subset.tar")
        #expect(dataset.totalBytes == 18_000_000_000)
        #expect(abs(dataset.fractionComplete - 0.08) < 0.001)
        #expect(dataset.status == .waitingForWiFi)
        #expect(dataset.currentSpeed == 0)  // nothing is moving, so the row shows no rate
        #expect(dataset.eta == nil)

        let blender = try fixture("Blender-4.2-macOS-arm64.dmg")
        #expect(blender.totalBytes == 412_300_000)
        #expect(blender.status == .completed)
        #expect(blender.checksumVerified)
        #expect(blender.fractionComplete == 1.0)
        let completedAt = try #require(blender.completedAt)
        #expect(completedAt == Self.now.addingTimeInterval(-120))  // "2m ago"
    }

    @Test("no fixture can put NaN or inf in front of a user")
    func everyDerivedNumberIsFinite() {
        for download in PreviewTransferEngine.fixtures(now: Self.now) {
            #expect(download.currentSpeed.isFinite, "\(download.filename) speed")
            #expect(download.currentSpeed >= 0, "\(download.filename) speed")
            #expect(download.fractionComplete.isFinite, "\(download.filename) fraction")
            if let eta = download.eta {
                #expect(eta.isFinite, "\(download.filename) eta")
                #expect(eta >= 0, "\(download.filename) eta")
            }
            #expect(download.speedSamples.allSatisfy { $0.isFinite }, "\(download.filename) samples")
            #expect(download.segments.allSatisfy { $0.fraction.isFinite }, "\(download.filename) segments")
        }
    }

    // MARK: - Engine behaviour

    @Test("the static engine starts holding exactly the fixtures")
    func staticEngineSeedsFromFixtures() async {
        let engine = PreviewTransferEngine.makeStatic(now: Self.now)
        let downloads = await engine.currentDownloads()
        #expect(downloads == PreviewTransferEngine.fixtures(now: Self.now))
    }

    @Test("the static engine emits one progress event per download and then stops")
    func staticEngineEmitsInitialProgress() async {
        let engine = PreviewTransferEngine.makeStatic(now: Self.now)

        let collector = Task {
            var ids: [UUID] = []
            for await event in engine.events {
                if case .progress = event { ids.append(event.downloadID) }
                if ids.count == 5 { break }
            }
            return ids
        }
        // Bound the wait: a regression should fail this test, not hang the whole suite.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            collector.cancel()
        }
        let ids = await collector.value
        watchdog.cancel()

        #expect(ids == PreviewTransferEngine.fixtures(now: Self.now).map(\.id))
    }

    @Test("pause deactivates every segment and reports the new status")
    func pauseMutatesAndReports() async {
        let engine = PreviewTransferEngine.makeStatic(now: Self.now)
        await engine.pause(PreviewTransferEngine.ubuntuID)

        let downloads = await engine.currentDownloads()
        let ubuntu = downloads.first { $0.id == PreviewTransferEngine.ubuntuID }
        #expect(ubuntu?.status == .paused)
        #expect(ubuntu?.segments.allSatisfy { !$0.isActive } == true)

        await engine.resume(PreviewTransferEngine.ubuntuID)
        let resumed = await engine.currentDownloads()
            .first { $0.id == PreviewTransferEngine.ubuntuID }
        #expect(resumed?.status == .downloading)
        // Segment 1 is finished, so resuming must not reactivate it.
        #expect(resumed?.segments.filter(\.isActive).count == 5)
    }

    @Test("cancel with deleteData discards the bytes and fails the download")
    func cancelDiscardsData() async {
        let engine = PreviewTransferEngine.makeStatic(now: Self.now)
        await engine.cancel(PreviewTransferEngine.nasBackupID, deleteData: true)

        let nas = await engine.currentDownloads()
            .first { $0.id == PreviewTransferEngine.nasBackupID }
        #expect(nas?.status == .failed)
        #expect(nas?.receivedBytes == 0)
        #expect(nas?.errorMessage == TransferError.cancelled.userMessage)
    }

    // MARK: - Probe (visual.html frame 3)

    @Test("probing the ubuntu link reproduces the add sheet")
    func probeReproducesAddSheet() async throws {
        let engine = PreviewTransferEngine.makeStatic(now: Self.now)
        let url = try #require(
            URL(string: "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso")
        )
        let result = try await engine.probe(url)
        #expect(result.filename == "ubuntu-24.04.1-desktop-amd64.iso")
        #expect(result.totalBytes == 5_730_000_000)      // "Size 5.73 GB"
        #expect(result.supportsResume)
        #expect(result.typeDescription == "Disk Image · resumable")  // "Type"
    }

    @Test("probing is deterministic and never touches the network")
    func probeIsDeterministic() async throws {
        let engine = PreviewTransferEngine.makeStatic(now: Self.now)
        let url = try #require(URL(string: "https://example.com/files/unknown-payload.bin"))
        let first = try await engine.probe(url)
        let second = try await engine.probe(url)
        #expect(first == second)
        #expect(first.filename == "unknown-payload.bin")
        #expect((first.totalBytes ?? 0) > 0)
    }

    @Test("probe rejects a scheme no engine can serve")
    func probeRejectsUnsupportedScheme() async throws {
        let engine = PreviewTransferEngine.makeStatic(now: Self.now)
        let url = try #require(URL(string: "smb://nas.local/share/payload.bin"))
        await #expect(throws: TransferError.unsupportedScheme("smb")) {
            _ = try await engine.probe(url)
        }
    }

    // MARK: - The seam itself

    @Test("every TransferError has a user-facing sentence")
    func errorsAreAllSpeakable() {
        let errors: [TransferError] = [
            .invalidURL, .unsupportedScheme("gopher"), .remoteFileChanged, .notFound,
            .network("timed out"), .cancelled, .diskFull, .checksumMismatch,
        ]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
            #expect(error.userMessage.first?.isUppercase == true)
        }
    }

    @Test("every event can be routed by download id without a full switch")
    func eventsCarryTheirDownloadID() throws {
        let id = PreviewTransferEngine.ubuntuID
        let url = try #require(URL(string: "file:///tmp/x"))
        let events: [TransferEvent] = [
            .progress(id: id, received: 1, total: 2, speed: 3, segments: []),
            .statusChanged(id: id, status: .paused),
            .completed(id: id, fileURL: url),
            .failed(id: id, message: "nope"),
        ]
        #expect(events.allSatisfy { $0.downloadID == id })
    }

    @Test("typeDescription covers the four shapes the add sheet can show")
    func typeDescriptions() {
        func describe(_ filename: String, mime: String?, resume: Bool, stream: Bool) -> String {
            ProbeResult(
                filename: filename, totalBytes: nil, supportsResume: resume,
                mimeType: mime, isStreamable: stream, validator: nil
            ).typeDescription
        }
        #expect(describe("a.iso", mime: nil, resume: true, stream: false) == "Disk Image · resumable")
        #expect(describe("a.mp4", mime: "video/mp4", resume: true, stream: true) == "Video · streamable")
        #expect(describe("a.tar.zst", mime: nil, resume: false, stream: false) == "Archive")
        #expect(describe("a.qqq", mime: nil, resume: false, stream: false) == "Unknown")
    }
}
