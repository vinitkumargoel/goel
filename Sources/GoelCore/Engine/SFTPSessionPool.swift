import Foundation

/// One connection per role — libssh2 is one-thread-per-session, so a background scan can't stall the interactive browser.
public enum SFTPSessionRole: Hashable, Sendable {
    case interactive
    case background
    case transfer(UUID)
}

/// Caps connections per server: OpenSSH's `MaxStartups 10:30:100` / `MaxSessions 10` would otherwise refuse at random.
public actor SFTPSessionPool {

    public static let shared = SFTPSessionPool()

    /// Keyed by where the server is and who we are, never by the credential — two clients for one login must share a connection.
    struct ServerKey: Hashable {
        let host: String
        let port: Int
        let username: String

        init(_ t: SFTPTarget) {
            host = t.host
            port = t.port
            username = t.username
        }
    }

    private struct ChannelKey: Hashable {
        let server: ServerKey
        let role: SFTPSessionRole
    }

    private var channels: [ChannelKey: SFTPSessionChannel] = [:]

    /// Only transfer jobs queue; interactive and background are always admitted rather than starving a folder listing.
    private let maxPerServer: Int

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [ServerKey: [Waiter]] = [:]

    /// A relay reserves both halves before opening either, so two concurrent relays can't each take one and deadlock.
    private var reserved: [ServerKey: Int] = [:]

    /// 6 = 1 interactive + 1 background + 4 folder-transfer streams, staying under OpenSSH's default `MaxSessions` of 10.
    public init(maxPerServer: Int = 6) {
        self.maxPerServer = max(2, maxPerServer)
    }

    /// `expected` is the pinned host-key fingerprint; a cached channel with different creds or pin is rebuilt so fixes apply at once.
    func channel(for target: SFTPTarget, role: SFTPSessionRole,
                 expected: String?) async -> SFTPSessionChannel {
        let server = ServerKey(target)
        let key = ChannelKey(server: server, role: role)
        if let existing = channels[key] {
            if existing.matches(target: target, expected: expected) { return existing }
            existing.shutdown()
            channels.removeValue(forKey: key)
            wakeWaiters(server)
        }

        // A transfer inside an explicit reservation already holds its slot; anything else claims one here and waits.
        let claimsOwnSlot: Bool
        if case .transfer = role { claimsOwnSlot = (reserved[server] ?? 0) == 0 } else { claimsOwnSlot = false }
        if claimsOwnSlot { await awaitSlot(server, count: 1) }

        // `awaitSlot` suspends, so another task may have created this channel meanwhile — re-check rather than orphan the winner.
        if let existing = channels[key], existing.matches(target: target, expected: expected) {
            if claimsOwnSlot { releaseReserved(server, count: 1) }
            return existing
        }

        let created = SFTPSessionChannel(target: target, expected: expected)
        channels[key] = created
        // The channel now holds the slot itself, so the reservation is spent — nothing was freed, so no waiter is woken.
        if claimsOwnSlot { consumeReserved(server, count: 1) }
        return created
    }

    /// Claim `count` slots at once (one at a time lets two relays deadlock). Must be balanced by ``release(_:count:)``.
    func reserve(_ target: SFTPTarget, count: Int) async {
        guard count > 0 else { return }
        await awaitSlot(ServerKey(target), count: count)
    }

    func release(_ target: SFTPTarget, count: Int) {
        guard count > 0 else { return }
        releaseReserved(ServerKey(target), count: count)
    }

    func releaseTransfer(_ id: UUID, target: SFTPTarget) {
        let server = ServerKey(target)
        let key = ChannelKey(server: server, role: .transfer(id))
        // Only a job that actually opened a channel frees a slot; waking a waiter otherwise admits a connection past the cap.
        guard let channel = channels.removeValue(forKey: key) else { return }
        channel.shutdown()
        wakeWaiters(server)
    }

    public func disconnectAll(matching target: SFTPTarget) {
        let server = ServerKey(target)
        for (key, channel) in channels where key.server == server {
            channel.shutdown()
            channels.removeValue(forKey: key)
        }
        wakeWaiters(server)
    }

    public func shutdownAll() {
        for channel in channels.values { channel.shutdown() }
        channels.removeAll()
        reserved.removeAll()
        // Abandoning a waiter's continuation would hang its task forever; resuming without slots is safe mid-teardown.
        for queue in waiters.values { for w in queue { w.continuation.resume() } }
        waiters.removeAll()
    }

    /// Counts slots promised but not yet opened, or the same slot could be handed out twice.
    private func liveCount(_ server: ServerKey) -> Int {
        channels.keys.reduce(0) { $0 + ($1.server == server ? 1 : 0) }
            + (reserved[server] ?? 0)
    }

    private func awaitSlot(_ server: ServerKey, count: Int) async {
        // Admitted straight away only when nobody is queued, so a two-slot relay isn't starved by one-slot jobs behind it.
        if (waiters[server]?.isEmpty ?? true), liveCount(server) + count <= maxPerServer {
            reserved[server, default: 0] += count
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters[server, default: []].append(Waiter(count: count, continuation: cont))
        }
    }

    private func consumeReserved(_ server: ServerKey, count: Int) {
        let remaining = (reserved[server] ?? 0) - count
        if remaining > 0 { reserved[server] = remaining } else { reserved.removeValue(forKey: server) }
    }

    private func releaseReserved(_ server: ServerKey, count: Int) {
        consumeReserved(server, count: count)
        wakeWaiters(server)
    }

    /// Oldest first, stopping at the first that doesn't fit — FIFO so a two-slot relay is never jumped indefinitely.
    private func wakeWaiters(_ server: ServerKey) {
        while let queue = waiters[server], let next = queue.first {
            guard liveCount(server) + next.count <= maxPerServer else { return }
            var rest = queue
            rest.removeFirst()
            if rest.isEmpty { waiters.removeValue(forKey: server) } else { waiters[server] = rest }
            // Charged before the resume so the woken task's slots can't be taken while it is being scheduled.
            reserved[server, default: 0] += next.count
            next.continuation.resume()
        }
    }
}
