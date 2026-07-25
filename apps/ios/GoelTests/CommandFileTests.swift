import Foundation
import Testing
@testable import Goel

/// T15's gate.
///
/// The command file is the only channel between a Dynamic Island tap and the transfer engine,
/// and it is written by two processes that never see each other. Everything that can go wrong
/// with it — a lost append, a double-applied pause, a command from an hour ago waking up and
/// pausing something the user just started, a half-written file from a jetsam kill — is
/// invisible in the simulator and obvious on a device. So it is all pinned here.
///
/// Every test injects its own temporary directory. Nothing here touches the real App Group
/// container, and no two tests can see each other's file.
@Suite("CommandFile")
struct CommandFileTests {

    // MARK: - Fixtures

    static func tempFile() -> CommandFile {
        CommandFile(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("GoelCommandTests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    /// A download id that looks like the real thing, because the drain parses it as a `UUID`.
    static func downloadID() -> String { UUID().uuidString }

    // MARK: - Writing

    @Test("A pause command lands on disk as a well-formed record")
    func pauseWritesAWellFormedRecord() throws {
        let file = Self.tempFile()
        let id = Self.downloadID()
        let issuedAt = Date(timeIntervalSince1970: 1_784_000_000)

        file.append(DownloadCommand(id: id, action: .pause, issuedAt: issuedAt))

        let data = try Data(contentsOf: file.fileURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let commands = try #require(root["commands"] as? [[String: Any]])
        #expect(commands.count == 1)

        // The wire shape the PRD names: {id, action, issuedAt}.
        #expect(commands[0]["id"] as? String == id)
        #expect(commands[0]["action"] as? String == "pause")
        let seconds = try #require(commands[0]["issuedAt"] as? Double)
        #expect(seconds == issuedAt.timeIntervalSince1970)

        // And it reads back as the value that was written.
        let pending = file.pending(now: issuedAt)
        #expect(pending.count == 1)
        #expect(pending[0].id == id)
        #expect(pending[0].action == .pause)
    }

    @Test("Every action round-trips through the file unchanged")
    func everyActionRoundTrips() {
        let file = Self.tempFile()
        let now = Date()
        let id = Self.downloadID()

        let written = [
            DownloadCommand(id: id, action: .pause, issuedAt: now.addingTimeInterval(-4)),
            DownloadCommand(id: id, action: .resume, issuedAt: now.addingTimeInterval(-3)),
            DownloadCommand(id: id, action: .cancel, issuedAt: now.addingTimeInterval(-2)),
            DownloadCommand(id: DownloadCommand.allID, action: .pauseAll, issuedAt: now.addingTimeInterval(-1)),
            DownloadCommand(id: id, action: .add, issuedAt: now, payload: "https://cdn.example.com/a.iso")
        ]
        for command in written { file.append(command, now: now) }

        // Oldest first — a pause-then-resume pair must not arrive reversed.
        #expect(file.pending(now: now) == written)
    }

    @Test("The same tap recorded twice is stored once")
    func identicalRecordsCollapse() {
        let file = Self.tempFile()
        let command = DownloadCommand(id: Self.downloadID(), action: .pause)
        file.append(command)
        file.append(command)
        #expect(file.pending().count == 1)
    }

    // MARK: - Draining

    @Test("Draining returns the pending commands and empties the file")
    func drainTruncates() {
        let file = Self.tempFile()
        let now = Date()
        let id = Self.downloadID()
        file.append(DownloadCommand(id: id, action: .pause, issuedAt: now), now: now)

        let drained = file.drain(now: now)
        #expect(drained.count == 1)
        #expect(drained[0].id == id)
        #expect(drained[0].action == .pause)
        #expect(file.pending(now: now).isEmpty)
    }

    @Test("Draining the same file twice applies it once")
    func drainIsIdempotent() {
        let file = Self.tempFile()
        let now = Date()
        let command = DownloadCommand(id: Self.downloadID(), action: .pause, issuedAt: now)
        file.append(command, now: now)

        #expect(file.drain(now: now).count == 1)
        #expect(file.drain(now: now).isEmpty)

        // And re-appending the *same record* — which is what a retried intent or a restored
        // container backup looks like — still does not apply it a second time. Truncation alone
        // would fail this; the applied-key ledger is what carries it.
        file.append(command, now: now)
        #expect(file.drain(now: now).isEmpty)
    }

    @Test("A stale command is discarded; a fresh one in the same file still applies")
    func staleCommandsAreDiscarded() {
        let file = Self.tempFile()
        let now = Date()
        let staleID = Self.downloadID()
        let freshID = Self.downloadID()

        let stale = DownloadCommand(id: staleID, action: .pause, issuedAt: now.addingTimeInterval(-7_200))
        let fresh = DownloadCommand(id: freshID, action: .pause, issuedAt: now.addingTimeInterval(-5))
        // Append as of the older instant so `append`'s own pruning does not decide the outcome
        // this test is about.
        file.append(stale, now: stale.issuedAt)
        file.append(fresh, now: stale.issuedAt)
        #expect(file.pending(now: stale.issuedAt).count == 2)

        let drained = file.drain(now: now)
        #expect(drained.count == 1)
        #expect(drained[0].id == freshID)
        #expect(file.pending(now: now).isEmpty)
    }

    @Test("Commands exactly at the age limit are honoured; a second past it are not")
    func stalenessBoundary() {
        let now = Date()
        let atLimit = DownloadCommand(id: "x", action: .pause, issuedAt: now.addingTimeInterval(-CommandFile.maxAge))
        let pastLimit = DownloadCommand(id: "x", action: .pause, issuedAt: now.addingTimeInterval(-CommandFile.maxAge - 1))
        #expect(!atLimit.isStale(at: now))
        #expect(pastLimit.isStale(at: now))
    }

    // MARK: - Two writers

    @Test("Concurrent appends from many threads all survive")
    func concurrentAppendsDoNotLoseUpdates() async {
        let file = Self.tempFile()
        let count = 24
        let ids = (0..<count).map { _ in Self.downloadID() }

        // `concurrentPerform` genuinely runs these on different threads, which is the shape of
        // the bug being guarded against: an unsynchronised read-modify-write silently drops
        // every append but the last, and the user sees a button that "sometimes works".
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.concurrentPerform(iterations: count) { i in
                    file.append(DownloadCommand(id: ids[i], action: .pause))
                }
                continuation.resume()
            }
        }

        let pending = file.pending()
        #expect(pending.count == count)
        #expect(Set(pending.map(\.id)) == Set(ids))
    }

    @Test("A concurrent append during a drain is not silently swallowed")
    func drainAndAppendInterleave() async {
        let file = Self.tempFile()
        let ids = (0..<12).map { _ in Self.downloadID() }
        for id in ids { file.append(DownloadCommand(id: id, action: .pause)) }

        let late = Self.downloadID()
        async let drained: [DownloadCommand] = Task.detached { file.drain() }.value
        async let appended: Void = Task.detached { file.append(DownloadCommand(id: late, action: .cancel)) }.value

        let first = await drained
        _ = await appended
        let rest = file.drain()

        // Whichever order the two landed in, every id is delivered exactly once.
        let delivered = (first + rest).map(\.id)
        #expect(Set(delivered) == Set(ids + [late]))
        #expect(delivered.count == ids.count + 1)
    }

    // MARK: - Corruption

    @Test("A garbage commands.json drains empty rather than crashing")
    func corruptFileDrainsEmpty() throws {
        let file = Self.tempFile()
        try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        try Data("{ \"commands\": [ this is half a write interrupted by a jetsam kill".utf8)
            .write(to: file.fileURL)

        #expect(file.pending().isEmpty)
        #expect(file.drain().isEmpty)

        // And the file must be usable afterwards — a bad read is not a poisoned channel.
        let id = Self.downloadID()
        file.append(DownloadCommand(id: id, action: .pause))
        #expect(file.drain().map(\.id) == [id])
    }

    @Test("An empty file and an absent file both drain empty")
    func emptyAndAbsentFilesDrainEmpty() throws {
        let absent = Self.tempFile()
        #expect(absent.drain().isEmpty)

        let empty = Self.tempFile()
        try FileManager.default.createDirectory(at: empty.directory, withIntermediateDirectories: true)
        try Data().write(to: empty.fileURL)
        #expect(empty.drain().isEmpty)
    }

    @Test("reset drops the file")
    func resetDropsTheFile() {
        let file = Self.tempFile()
        file.append(DownloadCommand(id: Self.downloadID(), action: .pause))
        #expect(FileManager.default.fileExists(atPath: file.fileURL.path))
        file.reset()
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(file.pending().isEmpty)
    }
}

// MARK: - Optimistic snapshot

/// The half of an intent the user sees before the app has run. Pure functions, so none of this
/// needs a container.
@Suite("OptimisticSnapshot")
struct OptimisticSnapshotTests {

    static func item(_ id: String, paused: Bool = false, speed: Double = 48_000_000) -> SharedSnapshot.Item {
        SharedSnapshot.Item(
            id: id,
            filename: "\(id).iso",
            fraction: 0.63,
            speed: speed,
            kindToken: "https",
            isPaused: paused
        )
    }

    static func snapshot(_ items: [SharedSnapshot.Item], activeCount: Int) -> SharedSnapshot {
        SharedSnapshot(
            activeCount: activeCount,
            totalRemainingBytes: 2_120_000_000,
            aggregateFraction: 0.63,
            updatedAt: Date(timeIntervalSince1970: 1_784_000_000),
            top: items
        )
    }

    @Test("A pause shows as paused immediately, and only for the row that was tapped")
    func pauseIsReflectedImmediately() {
        let before = Self.snapshot([Self.item("a"), Self.item("b")], activeCount: 2)
        let now = Date(timeIntervalSince1970: 1_784_000_100)

        let after = OptimisticSnapshot.apply(
            DownloadCommand(id: "a", action: .pause),
            to: before,
            now: now
        )

        #expect(after.top[0].isPaused)
        #expect(!after.top[1].isPaused)
        // A paused row still claiming 48 MB/s is a lie the user can read off the Lock Screen.
        #expect(after.top[0].speed == 0)
        #expect(after.activeCount == 1)
        #expect(after.updatedAt == now)
        // Progress is untouched: the intent knows what the user asked for, not how many bytes
        // arrived, and inventing a number here would make the bar jump when the app drains.
        #expect(after.aggregateFraction == before.aggregateFraction)
        #expect(after.totalRemainingBytes == before.totalRemainingBytes)
    }

    @Test("Pausing an already-paused row does not double-decrement the active count")
    func pauseIsIdempotentInTheSnapshot() {
        let before = Self.snapshot([Self.item("a", paused: true), Self.item("b")], activeCount: 1)
        let once = OptimisticSnapshot.apply(DownloadCommand(id: "a", action: .pause), to: before)
        #expect(once.activeCount == 1)
        let twice = OptimisticSnapshot.apply(DownloadCommand(id: "a", action: .pause), to: once)
        #expect(twice.activeCount == 1)
    }

    @Test("Resume clears the paused flag and restores the active count")
    func resumeIsReflectedImmediately() {
        let before = Self.snapshot([Self.item("a", paused: true, speed: 0), Self.item("b")], activeCount: 1)
        let after = OptimisticSnapshot.apply(DownloadCommand(id: "a", action: .resume), to: before)
        #expect(!after.top[0].isPaused)
        #expect(after.activeCount == 2)
    }

    @Test("Cancel removes the row")
    func cancelRemovesTheRow() {
        let before = Self.snapshot([Self.item("a"), Self.item("b")], activeCount: 2)
        let after = OptimisticSnapshot.apply(DownloadCommand(id: "a", action: .cancel), to: before)
        #expect(after.top.map(\.id) == ["b"])
        #expect(after.activeCount == 1)
    }

    @Test("Pause all pauses every row and zeroes the active count")
    func pauseAllPausesEverything() {
        let before = Self.snapshot([Self.item("a"), Self.item("b", paused: true), Self.item("c")], activeCount: 2)
        let after = OptimisticSnapshot.apply(
            DownloadCommand(id: DownloadCommand.allID, action: .pauseAll),
            to: before
        )
        let allPaused = after.top.allSatisfy(\.isPaused)
        #expect(allPaused)
        #expect(after.activeCount == 0)
    }

    @Test("Add invents no phantom row")
    func addDoesNotFabricateARow() {
        let before = Self.snapshot([Self.item("a")], activeCount: 1)
        let after = OptimisticSnapshot.apply(
            DownloadCommand(id: "new", action: .add, payload: "https://cdn.example.com/x.iso"),
            to: before
        )
        #expect(after.top.map(\.id) == ["a"])
        #expect(after.activeCount == 1)
    }

    @Test("A command naming a download the widget cannot see changes nothing")
    func unknownIDIsANoOp() {
        let before = Self.snapshot([Self.item("a")], activeCount: 1)
        let after = OptimisticSnapshot.apply(DownloadCommand(id: "ghost", action: .pause), to: before)
        #expect(after.top == before.top)
        #expect(after.activeCount == 1)
    }

    @Test("The active count never goes negative, however confused the snapshot is")
    func activeCountIsClamped() {
        let before = Self.snapshot([Self.item("a")], activeCount: 0)
        let after = OptimisticSnapshot.apply(DownloadCommand(id: "a", action: .pause), to: before)
        #expect(after.activeCount == 0)
    }
}

// MARK: - Drain into the app

/// The other end of the wire: a record on disk becomes a real engine call.
@Suite("CommandDrain")
@MainActor
struct CommandDrainTests {

    static func makeApp() -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoelDrainTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("downloads.json", isDirectory: false)
        return AppModel(engine: PreviewTransferEngine.makeStatic(), store: DownloadStore(persistenceURL: url))
    }

    static func make(_ name: String, status: Download.Status = .downloading) -> Download {
        Download(
            url: URL(string: "https://cdn.example.com/\(name)") ?? URL(fileURLWithPath: "/dev/null"),
            filename: name,
            saveDirectory: "Goel°",
            kind: .https,
            status: status,
            totalBytes: 1_000,
            receivedBytes: 100
        )
    }

    @Test("A pause command actually pauses the download, and the file is truncated")
    func pauseAppliesAndTruncates() {
        let app = Self.makeApp()
        let file = CommandFileTests.tempFile()
        let d = Self.make("ubuntu.iso")
        app.store.add(d)

        file.append(DownloadCommand(id: d.id.uuidString, action: .pause))
        let applied = CommandDrain.drain(into: app, from: file)

        #expect(applied.count == 1)
        #expect(app.store[d.id]?.status == .paused)
        #expect(file.pending().isEmpty)
    }

    @Test("Draining twice pauses once — a second drain must not toggle it back")
    func drainingTwiceAppliesOnce() {
        let app = Self.makeApp()
        let file = CommandFileTests.tempFile()
        let d = Self.make("ubuntu.iso")
        app.store.add(d)

        let command = DownloadCommand(id: d.id.uuidString, action: .pause)
        file.append(command)
        #expect(CommandDrain.drain(into: app, from: file).count == 1)
        #expect(app.store[d.id]?.status == .paused)

        // Launch, then foreground, then a background URLSession wake — three drains within a
        // second of each other is the normal case, not the pathological one.
        file.append(command)
        #expect(CommandDrain.drain(into: app, from: file).isEmpty)
        #expect(CommandDrain.drain(into: app, from: file).isEmpty)
        #expect(app.store[d.id]?.status == .paused)
    }

    @Test("Resume and cancel reach the store")
    func resumeAndCancelApply() {
        let app = Self.makeApp()
        let file = CommandFileTests.tempFile()
        let paused = Self.make("paused.iso", status: .paused)
        let doomed = Self.make("doomed.iso")
        app.store.add(paused)
        app.store.add(doomed)

        file.append(DownloadCommand(id: paused.id.uuidString, action: .resume))
        file.append(DownloadCommand(id: doomed.id.uuidString, action: .cancel))
        #expect(CommandDrain.drain(into: app, from: file).count == 2)

        #expect(app.store[paused.id]?.status == .downloading)
        #expect(app.store[doomed.id] == nil)
    }

    @Test("Pause all pauses every non-terminal row and leaves the library alone")
    func pauseAllApplies() {
        let app = Self.makeApp()
        let file = CommandFileTests.tempFile()
        let a = Self.make("a.iso")
        let b = Self.make("b.iso", status: .queued)
        let done = Self.make("c.zip", status: .completed)
        for d in [a, b, done] { app.store.add(d) }

        file.append(DownloadCommand(id: DownloadCommand.allID, action: .pauseAll))
        CommandDrain.drain(into: app, from: file)

        #expect(app.store[a.id]?.status == .paused)
        #expect(app.store[b.id]?.status == .paused)
        #expect(app.store[done.id]?.status == .completed)
    }

    @Test("An add command queues the URL")
    func addQueuesTheURL() {
        let app = Self.makeApp()
        let file = CommandFileTests.tempFile()

        file.append(
            DownloadCommand(
                id: UUID().uuidString,
                action: .add,
                payload: "https://releases.example.com/big-4gb.iso"
            )
        )
        CommandDrain.drain(into: app, from: file)

        #expect(app.store.downloads.count == 1)
        #expect(app.store.downloads[0].filename == "big-4gb.iso")
        #expect(app.store.downloads[0].kind == .https)
    }

    @Test("Commands naming a download that no longer exists are dropped, not crashed on")
    func unknownAndMalformedCommandsAreIgnored() {
        let app = Self.makeApp()
        let file = CommandFileTests.tempFile()
        let d = Self.make("survivor.iso")
        app.store.add(d)

        file.append(DownloadCommand(id: UUID().uuidString, action: .pause))
        file.append(DownloadCommand(id: "not-a-uuid", action: .cancel))
        file.append(DownloadCommand(id: UUID().uuidString, action: .add, payload: "not a url at all"))
        CommandDrain.drain(into: app, from: file)

        #expect(app.store.downloads.count == 1)
        #expect(app.store[d.id]?.status == .downloading)
    }

    @Test("A stale tap from an hour ago never pauses a transfer the user just started")
    func staleCommandsNeverApply() {
        let app = Self.makeApp()
        let file = CommandFileTests.tempFile()
        let d = Self.make("fresh.iso")
        app.store.add(d)

        let old = Date().addingTimeInterval(-7_200)
        file.append(DownloadCommand(id: d.id.uuidString, action: .pause, issuedAt: old), now: old)

        #expect(CommandDrain.drain(into: app, from: file).isEmpty)
        #expect(app.store[d.id]?.status == .downloading)
    }

    @Test("An empty drain is free — no store mutation, no snapshot churn")
    func emptyDrainChangesNothing() {
        let app = Self.makeApp()
        let file = CommandFileTests.tempFile()
        let d = Self.make("idle.iso")
        app.store.add(d)

        #expect(CommandDrain.drain(into: app, from: file).isEmpty)
        #expect(app.store[d.id]?.status == .downloading)
    }
}
