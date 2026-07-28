import XCTest
@testable import GoelCore

final class FakePower: PowerControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _onBattery: Bool
    private var _preventSleepCalls: [Bool] = []

    init(onBattery: Bool = false) { _onBattery = onBattery }

    var isOnBattery: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _onBattery }
        set { lock.lock(); _onBattery = newValue; lock.unlock() }
    }

    func setPreventSleep(_ on: Bool) {
        lock.lock(); _preventSleepCalls.append(on); lock.unlock()
    }

    var preventSleepCalls: [Bool] { lock.lock(); defer { lock.unlock() }; return _preventSleepCalls }
    var lastPreventSleep: Bool? { preventSleepCalls.last }
}

final class FakeFolderWatch: FolderWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (URL) -> Void)?
    private var _startedPaths: [String] = []
    private var _stopCount = 0

    func start(path: String, onNewTorrent: @escaping @Sendable (URL) -> Void) async {
        lock.lock(); _startedPaths.append(path); callback = onNewTorrent; lock.unlock()
    }

    func stop() async {
        lock.lock(); _stopCount += 1; callback = nil; lock.unlock()
    }

    func drop(_ url: URL) {
        lock.lock(); let cb = callback; lock.unlock()
        cb?(url)
    }

    var startedPaths: [String] { lock.lock(); defer { lock.unlock() }; return _startedPaths }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
}

final class FakeScanner: FileScanning, @unchecked Sendable {
    typealias Call = (path: String, executablePath: String, argumentTemplate: String)

    private let lock = NSLock()
    private let result: Bool
    private var _calls: [Call] = []

    init(result: Bool = true) { self.result = result }

    func scan(path: String, executablePath: String, argumentTemplate: String) async -> Bool {
        lock.lock(); _calls.append((path, executablePath, argumentTemplate)); lock.unlock()
        return result
    }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var scannedPaths: [String] { calls.map(\.path) }
}

final class PlatformPortsTests: XCTestCase {

    private let saveDir = NSTemporaryDirectory()

    private func urlSource(_ s: String) -> DownloadSource {
        .url(URL(string: s)!)
    }

    private func magnetSource(_ hash: String) -> DownloadSource {
        .magnet("magnet:?xt=urn:btih:\(hash)&dn=Demo+Pack")
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    private func powerSettings(
        preventSleepWhileDownloading: Bool = true,
        allowSleepIfResumable: Bool = false,
        allowSleepWhileSeeding: Bool = false,
        pauseBelowBatteryThreshold: Bool = false,
        dontSeedOnBattery: Bool = false
    ) -> AppSettings {
        AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: TrafficProfile.medium.name,
            defaultSaveDirectory: saveDir,
            preventSleepWhileDownloading: preventSleepWhileDownloading,
            allowSleepIfResumable: allowSleepIfResumable,
            allowSleepWhileSeeding: allowSleepWhileSeeding,
            pauseBelowBatteryThreshold: pauseBelowBatteryThreshold,
            dontSeedOnBattery: dontSeedOnBattery
        )
    }

    private func manager(
        _ settings: AppSettings,
        power: any PowerControlling = FakePower(),
        folderWatch: any FolderWatching = FakeFolderWatch(),
        scanner: any FileScanning = FakeScanner()
    ) -> DownloadManager {
        DownloadManager(
            httpEngine: FakeEngine(kind: .http),
            torrentEngine: FakeEngine(kind: .torrent),
            settings: settings,
            power: power,
            folderWatch: folderWatch,
            scanner: scanner
        )
    }

    private func activeDownloadManager(_ settings: AppSettings, power: FakePower) async -> DownloadManager {
        let m = manager(settings, power: power)
        let task = await m.add(source: urlSource("https://example.test/active.bin"))
        _ = await waitUntil { await m.task(task.id)?.status == .downloading }
        return m
    }

    private func seedingOnlyManager(_ settings: AppSettings, power: FakePower, hash: String) async -> DownloadManager {
        let torrent = FakeEngine(kind: .torrent)
        let m = DownloadManager(
            httpEngine: FakeEngine(kind: .http),
            torrentEngine: torrent,
            settings: settings,
            power: power,
            folderWatch: FakeFolderWatch(),
            scanner: FakeScanner()
        )
        let task = await m.add(source: magnetSource(hash))
        _ = await waitUntil { await m.task(task.id)?.status == .requestingMetadata }
        torrent.emit(.statusChanged(.seeding), for: task.id)
        _ = await waitUntil { await m.task(task.id)?.status == .seeding }
        return m
    }

    private func decideActive(_ settings: AppSettings, onBattery: Bool) async -> Bool {
        let m = await activeDownloadManager(settings, power: FakePower(onBattery: onBattery))
        return await m.shouldPreventSleep()
    }

    private func decideSeeding(_ settings: AppSettings, onBattery: Bool, hash: String) async -> Bool {
        let m = await seedingOnlyManager(settings, power: FakePower(onBattery: onBattery), hash: hash)
        return await m.shouldPreventSleep()
    }

    func testActiveDownloadBatteryMatrix() async throws {
        let onAC = await decideActive(powerSettings(), onBattery: false)
        XCTAssertTrue(onAC)

        let onBatteryNoOptOut = await decideActive(powerSettings(), onBattery: true)
        XCTAssertTrue(onBatteryNoOptOut)

        let resumableOnBattery = await decideActive(powerSettings(allowSleepIfResumable: true), onBattery: true)
        XCTAssertFalse(resumableOnBattery)
        let resumableOnAC = await decideActive(powerSettings(allowSleepIfResumable: true), onBattery: false)
        XCTAssertTrue(resumableOnAC)

        let thresholdOnBattery = await decideActive(powerSettings(pauseBelowBatteryThreshold: true), onBattery: true)
        XCTAssertFalse(thresholdOnBattery)

        let masterOff = await decideActive(powerSettings(preventSleepWhileDownloading: false), onBattery: false)
        XCTAssertFalse(masterOff)
    }

    func testSeedingOnlyBatteryMatrix() async throws {
        let onAC = await decideSeeding(powerSettings(), onBattery: false,
                                       hash: "1111111111111111111111111111111111111111")
        XCTAssertTrue(onAC)
        let onBattery = await decideSeeding(powerSettings(), onBattery: true,
                                            hash: "2222222222222222222222222222222222222222")
        XCTAssertTrue(onBattery)

        let allowSeedSleep = await decideSeeding(powerSettings(allowSleepWhileSeeding: true), onBattery: false,
                                                 hash: "3333333333333333333333333333333333333333")
        XCTAssertFalse(allowSeedSleep)

        let noSeedOnBattery = await decideSeeding(powerSettings(dontSeedOnBattery: true), onBattery: true,
                                                  hash: "4444444444444444444444444444444444444444")
        XCTAssertFalse(noSeedOnBattery)
        let noSeedOnAC = await decideSeeding(powerSettings(dontSeedOnBattery: true), onBattery: false,
                                             hash: "5555555555555555555555555555555555555555")
        XCTAssertTrue(noSeedOnAC)

        let masterOff = await decideSeeding(powerSettings(preventSleepWhileDownloading: false), onBattery: false,
                                            hash: "6666666666666666666666666666666666666666")
        XCTAssertFalse(masterOff)
    }

    func testIdleQueueNeverPreventsSleep() async throws {
        let m = manager(powerSettings(), power: FakePower(onBattery: false))
        let decision = await m.shouldPreventSleep()
        XCTAssertFalse(decision)
    }

    func testActiveDownloadDrivesPowerPort() async throws {
        let power = FakePower(onBattery: false)
        let m = manager(powerSettings(), power: power)
        let task = await m.add(source: urlSource("https://example.test/wired.bin"))
        let downloading = await waitUntil { await m.task(task.id)?.status == .downloading }
        XCTAssertTrue(downloading)
        let held = await waitUntil { power.lastPreventSleep == true }
        XCTAssertTrue(held)
    }

    func testWatchedTorrentAutoStartsWhenConfirmationNotRequired() async throws {
        let watch = FakeFolderWatch()
        let settings = AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: TrafficProfile.medium.name,
            defaultSaveDirectory: saveDir,
            btWatchFolderEnabled: true,
            btWatchFolderPath: "/watch",
            btWatchStartWithoutConfirmation: true
        )
        let m = manager(settings, folderWatch: watch)
        await m.updateWatchFolder()
        XCTAssertEqual(watch.startedPaths, ["/watch"])

        watch.drop(URL(fileURLWithPath: "/watch/movie.torrent"))

        let added = await waitUntil { await m.snapshot.count == 1 }
        XCTAssertTrue(added)
        let started = await waitUntil { await m.snapshot.first?.status == .downloading }
        XCTAssertTrue(started)
    }

    func testWatchedTorrentPausesWhenConfirmationRequired() async throws {
        let watch = FakeFolderWatch()
        let settings = AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: TrafficProfile.medium.name,
            defaultSaveDirectory: saveDir,
            btWatchFolderEnabled: true,
            btWatchFolderPath: "/watch",
            btWatchStartWithoutConfirmation: false
        )
        let m = manager(settings, folderWatch: watch)
        await m.updateWatchFolder()

        watch.drop(URL(fileURLWithPath: "/watch/series.torrent"))

        let added = await waitUntil { await m.snapshot.count == 1 }
        XCTAssertTrue(added)
        let paused = await waitUntil { await m.snapshot.first?.status == .paused }
        XCTAssertTrue(paused)
    }

    func testWatchFolderStopsWhenDisabled() async throws {
        let watch = FakeFolderWatch()
        let settings = AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: TrafficProfile.medium.name,
            defaultSaveDirectory: saveDir,
            btWatchFolderEnabled: false
        )
        let m = manager(settings, folderWatch: watch)
        await m.updateWatchFolder()
        XCTAssertTrue(watch.startedPaths.isEmpty)
        XCTAssertEqual(watch.stopCount, 1)
    }

    func testAntivirusScanInvokedWhenEnabledWithSavePath() async throws {
        let scanner = FakeScanner(result: true)
        let settings = AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: TrafficProfile.medium.name,
            defaultSaveDirectory: saveDir,
            antivirusEnabled: true,
            antivirusExecutablePath: "/usr/bin/clamscan",
            antivirusArgumentTemplate: "--quiet %path%"
        )
        let m = manager(settings, scanner: scanner)
        let task = await m.add(source: urlSource("https://example.test/clean.bin"))

        await m.onDownloadCompleted(task)

        let scanned = await waitUntil { scanner.calls.count == 1 }
        XCTAssertTrue(scanned)
        XCTAssertEqual(scanner.scannedPaths, [task.savePath])
        XCTAssertEqual(scanner.calls.first?.executablePath, "/usr/bin/clamscan")
        XCTAssertEqual(scanner.calls.first?.argumentTemplate, "--quiet %path%")
    }

    func testAntivirusScanSkippedWhenDisabled() async throws {
        let scanner = FakeScanner(result: true)
        let settings = AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: TrafficProfile.medium.name,
            defaultSaveDirectory: saveDir,
            antivirusEnabled: false
        )
        let m = manager(settings, scanner: scanner)
        let task = await m.add(source: urlSource("https://example.test/unchecked.bin"))

        await m.onDownloadCompleted(task)

        // Deliberately waits for something that must NOT happen.
        let scannedAnyway = await waitUntil(timeout: 0.5) { !scanner.calls.isEmpty }
        XCTAssertFalse(scannedAnyway)
    }
}
