import Foundation

/// Admission control for uploads to SFTP destinations: concurrency caps, per-path exclusion, and a per-server circuit breaker.
///
/// Every upload costs a full TCP + SSH + auth handshake on its own thread — ``SFTPClient`` deliberately never pools sessions — so twenty downloads finishing together would otherwise open twenty sessions at once. That exhausts threads and file descriptors here, and trips `MaxStartups` (or fail2ban) there.
public actor RemoteUploadCoordinator {

    /// Why a server is refusing new work.
    public enum Hold: Sendable, Equatable {
        /// Backing off after repeated failures; `until` is when the next attempt may run.
        case backoff(until: Date)
        /// A failure that retrying cannot fix — a changed host key, a rejected password. Cleared only by the user.
        case manual(reason: String)

        public var message: String {
            switch self {
            case .backoff(let until):
                let seconds = max(0, Int(until.timeIntervalSinceNow))
                return "Paused after repeated failures — retrying in \(seconds)s."
            case .manual(let reason):
                return reason
            }
        }
    }

    /// A failure that says something about the *server*, as opposed to about one file.
    ///
    /// Only these reach the breaker. A rejected path, a name collision, a cancelled transfer — those belong to the one download that hit them, and pausing every other upload to the same server because of one is how a single typo takes the whole destination offline.
    public enum Fault: Sendable, Equatable {
        /// Nothing will get through until a person fixes it: a changed host key, a rejected password.
        case unusable(reason: String)
        /// Reachable in principle — a refused connection, a dropped session. Backs off once the streak passes the threshold.
        case transient(reason: String)
    }

    /// Thrown by ``acquire(server:remotePath:)`` when the server is held. A queued upload must not sit behind a hold that only a person can clear.
    public struct ServerHeld: Error, Sendable {
        public let hold: Hold
    }

    private struct Breaker {
        var consecutiveFailures = 0
        var hold: Hold?
    }

    private var maxGlobal: Int
    private var maxPerServer: Int
    private var failureThreshold: Int

    private var globalInFlight = 0
    private var perServerInFlight: [UUID: Int] = [:]
    /// Claimed `connectionID|remotePath` pairs — two tasks writing one path would interleave truncating writes.
    private var claimedPaths: Set<String> = []
    private var breakers: [UUID: Breaker] = [:]

    /// How often a queued upload re-checks whether it may start. Uploads run for seconds to minutes, so a quarter-second of admission latency is invisible — and polling keeps cancellation correct for free, where hand-rolled continuation bookkeeping would not.
    public static let defaultPollInterval: UInt64 = 250_000_000

    /// Overridable so tests can assert on admission without sleeping a real quarter-second per case.
    private let pollInterval: UInt64

    /// Longest backoff between attempts against one server.
    static let maxBackoff: TimeInterval = 30 * 60

    public init(maxGlobal: Int = 4, maxPerServer: Int = 2, failureThreshold: Int = 3,
                pollInterval: UInt64 = RemoteUploadCoordinator.defaultPollInterval) {
        self.maxGlobal = max(1, maxGlobal)
        self.maxPerServer = max(1, maxPerServer)
        self.failureThreshold = max(1, failureThreshold)
        self.pollInterval = max(1, pollInterval)
    }

    /// Apply changed settings. In-flight uploads keep their slots; a lowered cap takes effect as they drain.
    public func configure(maxGlobal: Int, maxPerServer: Int, failureThreshold: Int) {
        self.maxGlobal = max(1, maxGlobal)
        self.maxPerServer = max(1, maxPerServer)
        self.failureThreshold = max(1, failureThreshold)
    }

    // MARK: Admission

    /// Wait for a slot on `server` and exclusive claim of `remotePath`.
    ///
    /// Waits only for things that clear themselves — a busy slot, a claimed path. A hold throws ``ServerHeld`` instead, because a manual hold clears only when a person acts and polling for it would leave the upload queued in silence forever.
    ///
    /// Throws `CancellationError` if the caller is cancelled while queued. Either way nothing is reserved.
    public func acquire(server: UUID, remotePath: String) async throws {
        let key = Self.pathKey(server, remotePath)
        while true {
            if let hold = currentHold(server) { throw ServerHeld(hold: hold) }
            if canStart(server: server, pathKey: key) { break }
            try await Task.sleep(nanoseconds: pollInterval)
        }
        globalInFlight += 1
        perServerInFlight[server, default: 0] += 1
        claimedPaths.insert(key)
    }

    /// Give back a slot and its path claim. Safe to call once per successful ``acquire(server:remotePath:)`` and never otherwise.
    public func release(server: UUID, remotePath: String) {
        globalInFlight = max(0, globalInFlight - 1)
        if let n = perServerInFlight[server] {
            if n <= 1 { perServerInFlight[server] = nil } else { perServerInFlight[server] = n - 1 }
        }
        claimedPaths.remove(Self.pathKey(server, remotePath))
    }

    private func canStart(server: UUID, pathKey: String) -> Bool {
        guard globalInFlight < maxGlobal else { return false }
        guard perServerInFlight[server, default: 0] < maxPerServer else { return false }
        return !claimedPaths.contains(pathKey)
    }

    private static func pathKey(_ server: UUID, _ path: String) -> String { "\(server.uuidString)|\(path)" }

    // MARK: Circuit breaker

    /// Clear a server's failure streak. Called on every verified upload.
    public func recordSuccess(server: UUID) {
        breakers[server] = nil
    }

    /// Record a server-level fault. Only ``Fault`` values reach here — a failure scoped to one download must never pause the server for every other one.
    public func recordFailure(server: UUID, fault: Fault) {
        var breaker = breakers[server] ?? Breaker()
        breaker.consecutiveFailures += 1
        if case .unusable(let reason) = fault {
            breaker.hold = .manual(reason: reason)
        } else if breaker.consecutiveFailures >= failureThreshold {
            // Counted from the threshold so the first backoff is the base delay, not one already doubled several times.
            let steps = breaker.consecutiveFailures - failureThreshold
            let delay = min(Self.maxBackoff, 30 * pow(2, Double(steps)))
            breaker.hold = .backoff(until: Date().addingTimeInterval(delay))
        }
        breakers[server] = breaker
    }

    /// Why `server` is refusing work, or nil if it is available. Expired backoffs clear themselves here.
    public func currentHold(_ server: UUID) -> Hold? {
        guard let breaker = breakers[server], let hold = breaker.hold else { return nil }
        if case .backoff(let until) = hold, until <= Date() {
            var cleared = breaker
            cleared.hold = nil
            breakers[server] = cleared
            return nil
        }
        return hold
    }

    /// Clear a hold and its failure streak — the user's "try again now".
    public func reset(server: UUID) {
        breakers[server] = nil
    }

    /// Servers currently refusing work, for the UI.
    public func heldServers() -> [UUID: Hold] {
        var out: [UUID: Hold] = [:]
        for id in breakers.keys {
            if let hold = currentHold(id) { out[id] = hold }
        }
        return out
    }

    /// Uploads in flight right now — used to decide whether shutdown must wait.
    public func inFlightCount() -> Int { globalInFlight }
}
