import XCTest
import Foundation
@testable import GoelContracts
@testable import GoelCore
@testable import GoelFacade

/// Exercises the non-async facade — the actor→sync bridge and the AsyncStream→
/// callback path — the way a JNI/C-ABI consumer will: from a *synchronous* call
/// site. Every test method here is deliberately non-`async`, so the calling thread
/// is an ordinary thread (a stand-in for a JVM thread), never one of Swift's
/// cooperative-pool workers — which is the contract ``runBlocking`` relies on.
final class GoelFacadeTests: XCTestCase {

    /// The facade takes a fully-composed manager; it deliberately offers no
    /// "mobile composition" convenience init, because the default ports
    /// (`DittoArchiveExtractor`, `ProcessFileScan`) spawn `Foundation.Process`,
    /// which does not exist on iOS. Composition is the call site's job.
    private func makeFacade(_ settings: AppSettings = AppSettings()) -> GoelFacade {
        GoelFacade(manager: DownloadManager(settings: settings))
    }

    private func decodeTasks(_ data: Data) throws -> [DownloadTask] {
        try GoelFacade.makeDecoder().decode([DownloadTask].self, from: data)
    }

    private func decodeTask(_ data: Data) throws -> DownloadTask {
        try GoelFacade.makeDecoder().decode(DownloadTask.self, from: data)
    }

    // MARK: Blocking bridge round-trips

    func test_snapshot_startsEmpty() throws {
        XCTAssertEqual(try decodeTasks(makeFacade().snapshotJSON()), [])
    }

    func test_add_returnsTaskJSON_andAppearsInSnapshot() throws {
        let facade = makeFacade()
        let added = try decodeTask(facade.add("https://example.com/a.zip", startPaused: true))
        XCTAssertEqual(added.source.locator, "https://example.com/a.zip")

        let snapshot = try decodeTasks(facade.snapshotJSON())
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.id, added.id)
    }

    func test_add_rejectsDisallowedScheme() {
        XCTAssertThrowsError(try makeFacade().add("file:///etc/passwd")) { error in
            XCTAssertEqual(error as? FacadeError, .invalidSource("file:///etc/passwd"))
        }
    }

    // MARK: Save-directory containment (mirrors the portal's guard)

    func test_add_rejectsSaveDirectoryOutsideDownloadsRoot() throws {
        var settings = AppSettings()
        settings.defaultSaveDirectory = NSTemporaryDirectory() + "goel-root"
        let facade = makeFacade(settings)

        XCTAssertThrowsError(try facade.add("https://example.com/x.zip",
                                            saveDirectory: "/etc/cron.d")) { error in
            XCTAssertEqual(error as? FacadeError, .disallowedSaveDirectory("/etc/cron.d"))
        }
        XCTAssertEqual(try decodeTasks(facade.snapshotJSON()).count, 0, "nothing may be queued")
    }

    func test_add_acceptsSaveDirectoryInsideRoot() throws {
        var settings = AppSettings()
        let root = NSTemporaryDirectory() + "goel-root"
        settings.defaultSaveDirectory = root
        let facade = makeFacade(settings)

        let task = try decodeTask(facade.add("https://example.com/y.zip",
                                             saveDirectory: root + "/sub", startPaused: true))
        XCTAssertEqual(task.saveDirectory, root + "/sub")
    }

    func test_add_emptySaveDirectoryFallsBackToDefault_notARelativePath() throws {
        var settings = AppSettings()
        settings.defaultSaveDirectory = NSTemporaryDirectory() + "goel-root"
        let facade = makeFacade(settings)

        let task = try decodeTask(facade.add("https://example.com/z.zip",
                                             saveDirectory: "   ", startPaused: true))
        XCTAssertTrue(task.saveDirectory.hasPrefix("/"), "got \(task.saveDirectory)")
    }

    // MARK: Per-task ops report an outcome (no silent no-ops)

    func test_pause_reportsOkAndPausesTask() throws {
        let facade = makeFacade()
        let task = try decodeTask(facade.add("https://example.com/b.bin"))

        XCTAssertEqual(facade.pause(task.id.uuidString), .ok)
        XCTAssertEqual(try decodeTasks(facade.snapshotJSON()).first?.status, .paused)
    }

    func test_perTaskOps_distinguishInvalidIDFromUnknownTask() {
        let facade = makeFacade()
        XCTAssertEqual(facade.pause("not-a-uuid"), .invalidID)
        XCTAssertEqual(facade.pause(UUID().uuidString), .notFound)
        XCTAssertEqual(facade.remove("nope", deleteData: false), .invalidID)
        XCTAssertEqual(facade.resume(UUID().uuidString), .notFound)
    }

    func test_remove_deletesTheTask() throws {
        let facade = makeFacade()
        let task = try decodeTask(facade.add("https://example.com/c.bin", startPaused: true))
        XCTAssertEqual(facade.remove(task.id.uuidString, deleteData: false), .ok)
        XCTAssertEqual(try decodeTasks(facade.snapshotJSON()).count, 0)
    }

    // MARK: Settings — patch semantics, not wholesale replace

    func test_updateSettings_appliesPatchWithoutResettingOtherFields() throws {
        var settings = AppSettings()
        settings.retryCount = 9
        settings.remoteUsername = "vinit"
        let facade = makeFacade(settings)

        // The natural settings-screen call: one key. Everything else must survive.
        try facade.updateSettings(Data(#"{"theme":"dark"}"#.utf8))

        let reloaded = try GoelFacade.makeDecoder().decode(AppSettings.self, from: facade.settingsJSON())
        XCTAssertEqual(reloaded.theme, "dark")
        XCTAssertEqual(reloaded.retryCount, 9, "a one-key patch must not reset unrelated fields")
        XCTAssertEqual(reloaded.remoteUsername, "vinit")
    }

    func test_updateSettings_throwsOnMalformedJSON() {
        let facade = makeFacade()
        XCTAssertThrowsError(try facade.updateSettings(Data("not json".utf8)))
        XCTAssertThrowsError(try facade.updateSettings(Data("[1,2,3]".utf8)))
    }

    // MARK: Secrets never cross the boundary — and are never destroyed by a round-trip

    func test_settingsJSON_omitsSecrets() throws {
        var settings = AppSettings()
        settings.remoteToken = "super-secret-bearer"
        settings.remotePasswordHash = "v1$abc$def"
        let facade = makeFacade(settings)

        let json = String(decoding: try facade.settingsJSON(), as: UTF8.self)
        XCTAssertFalse(json.contains("super-secret-bearer"))
        XCTAssertFalse(json.contains("v1$abc$def"))
        XCTAssertFalse(json.contains("remoteToken"))
        XCTAssertFalse(json.contains("remotePasswordHash"))
    }

    /// Redaction alone would turn a leak into data loss: a read-modify-write cycle
    /// would decode the absent token as its default and wipe the user's credential.
    func test_readModifyWrite_preservesSecrets() throws {
        var settings = AppSettings()
        settings.remoteToken = "keep-me"
        settings.remotePasswordHash = "v1$salt$hash"
        let facade = makeFacade(settings)

        try facade.updateSettings(facade.settingsJSON())          // the round-trip
        let live = runBlocking { await facade.managerForTesting.currentSettings }
        XCTAssertEqual(live.remoteToken, "keep-me")
        XCTAssertEqual(live.remotePasswordHash, "v1$salt$hash")
    }

    func test_updateSettings_cannotInjectSecrets() throws {
        var settings = AppSettings()
        settings.remoteToken = "original"
        let facade = makeFacade(settings)

        try facade.updateSettings(Data(#"{"remoteToken":"attacker-chosen"}"#.utf8))

        let live = runBlocking { await facade.managerForTesting.currentSettings }
        XCTAssertEqual(live.remoteToken, "original")
    }

    // MARK: schemaVersion passthrough

    func test_schemaVersion_matchesContract() {
        XCTAssertEqual(makeFacade().schemaVersion, GoelContract.schemaVersion)
    }

    // MARK: Callback path (AsyncStream → onSnapshot callback)

    func test_observe_firesImmediatelyWithCurrentSnapshot() {
        let facade = makeFacade()
        let fired = expectation(description: "callback fires with initial snapshot")
        let received = Locked<[Data]>([])

        let handle = facade.observe { data in
            received.mutate { $0.append(data) }
            fired.fulfill()
        }
        defer { facade.cancel(handle) }

        wait(for: [fired], timeout: 5)
        XCTAssertFalse(received.value.isEmpty)
    }

    func test_observe_deliversUpdateAfterAdd() throws {
        let facade = makeFacade()
        let sawTask = expectation(description: "callback delivers the added task")
        let done = Locked(false)

        let handle = facade.observe { data in
            guard let tasks = try? GoelFacade.makeDecoder().decode([DownloadTask].self, from: data),
                  !tasks.isEmpty else { return }
            done.mutate { if !$0 { $0 = true; sawTask.fulfill() } }
        }
        defer { facade.cancel(handle) }

        _ = try facade.add("https://example.com/d.bin", startPaused: true)
        wait(for: [sawTask], timeout: 5)
    }

    /// `cancel` must be *quiescent*: once it returns, no further callback can run.
    /// A JNI caller releases its callback reference right after cancelling, so an
    /// in-flight callback afterwards would be a use-after-free.
    func test_cancel_isQuiescent() throws {
        let facade = makeFacade()
        let first = expectation(description: "initial snapshot")
        let count = Locked(0)

        let handle = facade.observe { _ in
            count.mutate { $0 += 1 }
            first.fulfill()
        }
        wait(for: [first], timeout: 5)

        facade.cancel(handle)
        let atCancel = count.value          // sampled AFTER cancel returned

        _ = try facade.add("https://example.com/e.bin", startPaused: true)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(count.value, atCancel, "no callback may run after cancel returns")
    }

    /// The callback must not run on the cooperative pool: re-entering a blocking
    /// facade method from inside a callback is the most natural thing a consumer
    /// does, and on a pool thread it parks that thread and starves the runtime.
    func test_callbackMayReenterBlockingMethods() throws {
        let facade = makeFacade()
        let reentered = expectation(description: "callback re-entered a blocking call")
        let done = Locked(false)

        let handle = facade.observe { _ in
            let json = try? facade.snapshotJSON()          // re-entrant blocking call
            done.mutate {
                if !$0, json != nil { $0 = true; reentered.fulfill() }
            }
        }
        defer { facade.cancel(handle) }

        wait(for: [reentered], timeout: 5)
    }

    func test_multipleSubscriptions_getIndependentHandles() {
        let facade = makeFacade()
        let h1 = facade.observe { _ in }
        let h2 = facade.observe { _ in }
        XCTAssertNotEqual(h1, h2)
        XCTAssertNotEqual(h1, 0, "handle 0 is reserved as a C null sentinel")
        facade.cancel(h1)
        facade.cancel(h2)
        facade.cancel(h1)   // double-cancel is a no-op
    }
}

/// A tiny lock-guarded box so callbacks (which run on a private queue) can hand
/// values back to the synchronous test body without data races.
private final class Locked<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()
    init(_ value: Value) { _value = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&_value) }
}
