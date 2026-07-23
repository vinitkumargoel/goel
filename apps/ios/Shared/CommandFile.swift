import Foundation
import os

/// The App Group IPC that makes the Live Activity buttons real.
///
/// An App Intent tapped from the Dynamic Island does **not** run inside the app. It runs in
/// another process entirely, with no access to `DownloadStore`, no access to the engine actor,
/// and no guarantee the app is even alive. So the intent does not "pause a download" — it
/// *records the intent to pause* in a file both processes can see, and the app applies it the
/// next time it runs. **This file is the IPC.** Nothing cleverer is required and nothing
/// cleverer survives contact with a device.
///
/// Compiled into both targets, so it may not mention `Download`, `DownloadStore` or `AppModel`;
/// ``DownloadCommandAction`` is a plain `String`-backed enum for exactly that reason.
///
/// Three properties are load-bearing:
///
/// 1. **Two processes write it.** Every access goes through `NSFileCoordinator` plus a
///    process-local lock, and every write is an atomic replace. A torn read-modify-write here
///    is a lost tap, which the user experiences as "the pause button does nothing".
/// 2. **Draining is idempotent.** A background wake, a foreground transition and a launch can
///    all land within a second of each other. Applying the same pause twice would toggle the
///    download back to downloading, so applied commands are remembered by key for an hour.
/// 3. **It never throws and never blocks the caller.** A failed command write costs one tap.
///    A crash in a widget extension costs the whole Live Activity.

// MARK: - Action

/// What the user asked for. `String`-backed so the record survives an app update that adds
/// cases, and so this file stays free of app-only types.
public enum DownloadCommandAction: String, Codable, Sendable, CaseIterable {
    case pause
    case resume
    case cancel
    case pauseAll
    case add
}

// MARK: - Record

/// One tap, as it appears on disk: `{id, action, issuedAt}` plus an optional action-specific
/// payload (the URL, for ``DownloadCommandAction/add``).
public struct DownloadCommand: Codable, Sendable, Equatable {

    /// The download's `UUID` string, or ``DownloadCommand/allID`` for a fleet-wide action.
    public var id: String
    public var action: DownloadCommandAction
    public var issuedAt: Date
    /// `.add` carries the absolute URL string here. Every other action leaves it `nil`.
    public var payload: String?

    public init(id: String, action: DownloadCommandAction, issuedAt: Date = Date(), payload: String? = nil) {
        self.id = id
        self.action = action
        // Quantise to whole microseconds — the same resolution `key` uses. A `Date` written to
        // JSON as a Double and read back is not bit-identical, so without this a command is not
        // `==` its own round-trip, and two records that differ only by sub-microsecond noise
        // would look like distinct commands to the idempotency ledger.
        let micros = (issuedAt.timeIntervalSince1970 * 1_000_000).rounded()
        self.issuedAt = Date(timeIntervalSince1970: micros / 1_000_000)
        self.payload = payload
    }

    /// The well-known id for actions that address the whole queue rather than one download.
    public static let allID = "all"

    /// The idempotency key: action, id and issue time together.
    ///
    /// Microsecond resolution, because two taps a few milliseconds apart are two commands and
    /// collapsing them would drop one. Deliberately **not** a random UUID — a record that is
    /// written once and drained twice has to hash the same both times.
    public var key: String {
        let micros = Int64((issuedAt.timeIntervalSince1970 * 1_000_000).rounded())
        return "\(action.rawValue)|\(id)|\(micros)"
    }

    /// Commands older than ``CommandFile/maxAge`` are not worth applying — pausing a transfer
    /// because of a tap from two hours ago is a bug, not a feature.
    public func isStale(at now: Date, maxAge: TimeInterval = CommandFile.maxAge) -> Bool {
        // `issuedAt` is quantised to whole microseconds by `init`, so an age computed against a
        // raw `now` carries up to half a microsecond of rounding slop. Comparing at finer
        // resolution than the timestamps themselves hold would make a command issued *exactly*
        // `maxAge` ago stale or fresh at random, so the boundary is widened by one microsecond.
        now.timeIntervalSince(issuedAt) > maxAge + 1e-6
    }
}

// MARK: - File

public struct CommandFile: Sendable {

    /// How long a command stays actionable, and how long an applied key is remembered.
    public static let maxAge: TimeInterval = 60 * 60
    /// A hard ceiling so a wedged app cannot let the queue grow without bound.
    public static let maxPending = 256
    public static let fileName = "commands.json"

    /// The directory the file lives in. Tests inject a temporary one; production uses the
    /// App Group container.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The real one, in the App Group container. Falls back the same way ``SharedSnapshot``
    /// does, so a simulator without the entitlement degrades instead of crashing.
    public static let shared = CommandFile(
        directory: SharedSnapshot.containerURL() ?? FileManager.default.temporaryDirectory
    )

    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private static let logger = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "CommandFile")

    /// Serialises this process's own accesses. `NSFileCoordinator` handles the cross-process
    /// half; without this, two `Task`s in the widget extension can still interleave a
    /// read-modify-write and lose a tap.
    private static let lock = NSLock()

    // MARK: - Wire format

    /// `commands` is the queue; `applied` is the idempotency ledger. Keeping them in one file
    /// means one coordinated write per operation instead of two that can disagree.
    private struct Envelope: Codable {
        var version: Int = 1
        var commands: [DownloadCommand] = []
        var applied: [Applied] = []

        init(version: Int = 1, commands: [DownloadCommand] = [], applied: [Applied] = []) {
            self.version = version
            self.commands = commands
            self.applied = applied
        }

        /// Every key is optional on the way in. A file written by an older build — or by a
        /// build that had not invented the ledger yet — must still read, because the
        /// alternative is silently discarding the user's taps after an app update.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            commands = try c.decodeIfPresent([DownloadCommand].self, forKey: .commands) ?? []
            applied = try c.decodeIfPresent([Applied].self, forKey: .applied) ?? []
        }
    }

    private struct Applied: Codable, Equatable {
        var key: String
        var at: Date
    }

    // MARK: - Writes

    /// Records a command. Best effort: a failure costs the user one tap, never the process.
    public func append(_ command: DownloadCommand, now: Date = Date()) {
        mutate { env in
            env.commands.removeAll { $0.isStale(at: now) }
            // Same key twice is the same tap twice — the second one is noise.
            guard !env.commands.contains(where: { $0.key == command.key }) else { return }
            env.commands.append(command)
            if env.commands.count > Self.maxPending {
                env.commands.removeFirst(env.commands.count - Self.maxPending)
            }
        }
    }

    /// Applies-once semantics: returns every pending, non-stale command that has not been
    /// returned before, records their keys, and empties the queue.
    ///
    /// Draining twice returns the second call nothing — both because the queue is emptied and,
    /// independently, because the keys are remembered. The belt and the braces are both wanted:
    /// truncation alone loses to a crash between "read" and "write", and iOS will happily kill
    /// a background-launched app in that window.
    @discardableResult
    public func drain(now: Date = Date()) -> [DownloadCommand] {
        var applied: [DownloadCommand] = []
        mutate { env in
            var ledger = env.applied.filter { now.timeIntervalSince($0.at) <= Self.maxAge }
            var seen = Set(ledger.map(\.key))

            // Oldest first: pause-then-resume must not arrive as resume-then-pause.
            for command in env.commands.sorted(by: { $0.issuedAt < $1.issuedAt }) {
                guard !command.isStale(at: now) else { continue }
                guard seen.insert(command.key).inserted else { continue }
                ledger.append(Applied(key: command.key, at: now))
                applied.append(command)
            }

            env.commands = []
            env.applied = ledger
        }
        return applied
    }

    /// Drops the file. Tests use it; the app has no reason to.
    public func reset() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL,
            options: .forDeleting,
            error: &coordinationError
        ) { target in
            try? FileManager.default.removeItem(at: target)
        }
    }

    // MARK: - Reads

    /// Non-destructive: what a drain right now would return. Exists for tests and for the
    /// debug screen — the app itself should always ``drain(now:)``.
    public func pending(now: Date = Date()) -> [DownloadCommand] {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        var env = Envelope()
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: fileURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { target in
            env = Self.readEnvelope(at: target)
        }

        let seen = Set(env.applied.filter { now.timeIntervalSince($0.at) <= Self.maxAge }.map(\.key))
        return env.commands
            .filter { !$0.isStale(at: now) && !seen.contains($0.key) }
            .sorted { $0.issuedAt < $1.issuedAt }
    }

    // MARK: - Plumbing

    /// Coordinated, locked, atomic read-modify-write. The only way this file is ever changed.
    private func mutate(_ body: (inout Envelope) -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let url = fileURL
        var writeError: Error?
        var coordinationError: NSError?

        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { target in
            var env = Self.readEnvelope(at: target)
            body(&env)
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .secondsSince1970
                try encoder.encode(env).write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            Self.logger.error("Command file coordination failed: \(coordinationError.localizedDescription, privacy: .public)")
        }
        if let writeError {
            Self.logger.error("Command file write failed: \(writeError.localizedDescription, privacy: .public)")
        }
    }

    /// A missing file is an empty queue. A corrupt file is *also* an empty queue — a widget
    /// extension that traps on garbage JSON takes the Live Activity down with it, and the next
    /// write repairs the file anyway.
    private static func readEnvelope(at url: URL) -> Envelope {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return Envelope() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let env = try? decoder.decode(Envelope.self, from: data) { return env }
        // Tolerate the bare-array shape a hand-written or older file might use.
        if let commands = try? decoder.decode([DownloadCommand].self, from: data) {
            return Envelope(version: 1, commands: commands, applied: [])
        }
        logger.warning("commands.json unreadable; treating as empty.")
        return Envelope()
    }
}

// MARK: - Optimistic snapshot

/// The half of an intent that the user actually sees.
///
/// PRD §6.5 requires the queue to reflect a tap *immediately*. The app may be suspended for
/// another thirty seconds, so the intent rewrites ``SharedSnapshot`` itself before returning:
/// the Live Activity redraws as paused at once, and the app's own snapshot overwrites this one
/// with the truth as soon as it drains.
///
/// The transform is a pure function so it can be tested without an App Group container.
public enum OptimisticSnapshot {

    /// The snapshot as it will look once `command` has been applied.
    public static func apply(
        _ command: DownloadCommand,
        to snapshot: SharedSnapshot,
        now: Date = Date()
    ) -> SharedSnapshot {
        var items = snapshot.top
        var activeCount = snapshot.activeCount

        switch command.action {
        case .pause:
            for i in items.indices where items[i].id == command.id && !items[i].isPaused {
                items[i].isPaused = true
                // A paused row still showing 48 MB/s is a lie the user can read.
                items[i].speed = 0
                activeCount -= 1
            }

        case .resume:
            for i in items.indices where items[i].id == command.id && items[i].isPaused {
                items[i].isPaused = false
                activeCount += 1
            }

        case .cancel:
            let removed = items.filter { $0.id == command.id }
            items.removeAll { $0.id == command.id }
            activeCount -= removed.filter { !$0.isPaused }.count

        case .pauseAll:
            for i in items.indices where !items[i].isPaused {
                items[i].isPaused = true
                items[i].speed = 0
            }
            activeCount = 0

        case .add:
            // The widget has no filename, no size and no id for a download that does not exist
            // yet. Guessing one would put a phantom row in the Live Activity; the app fills it
            // in on the next drain instead.
            break
        }

        return SharedSnapshot(
            activeCount: max(0, activeCount),
            totalRemainingBytes: snapshot.totalRemainingBytes,
            aggregateFraction: snapshot.aggregateFraction,
            updatedAt: now,
            top: items
        )
    }

    /// Read, transform, write — the version the intents call.
    public static func record(_ command: DownloadCommand, now: Date = Date()) {
        SharedSnapshot.write(apply(command, to: SharedSnapshot.read(), now: now))
    }
}
