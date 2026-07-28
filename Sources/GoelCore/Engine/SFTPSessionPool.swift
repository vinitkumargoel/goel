import Foundation

/// Which kind of work a connection carries. Each role gets its own connection so a background scan
/// or big transfer can't stall the browser — libssh2's one-thread-per-session rule keeps them apart.
public enum SFTPSessionRole: Hashable, Sendable {
    /// Folder listings and the small mutations a person triggers directly. Must
    /// stay responsive above everything else.
    case interactive
    /// Recursive walks, folder sizing, delete pre-scans, thumbnails, search.
    case background
    /// One transfer job — a single file, or a whole folder. Reused across every
    /// file in that job, which is what removes the per-file handshake.
    case transfer(UUID)
}

/// Hands out connections keyed by server and role, capping how many one server holds open at once.
/// OpenSSH defaults (`MaxStartups` 10:30:100, `MaxSessions` 10) would otherwise refuse — random failures.
public actor SFTPSessionPool {

    public static let shared = SFTPSessionPool()

    /// Servers are identified by where they are and who we are, never by the
    /// credential — two clients for the same login must share a connection.
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

    /// Most connections one server may hold at once. Interactive and background are always admitted;
    /// only transfer jobs queue — starving a folder listing for a fifth upload is the wrong trade.
    private let maxPerServer: Int

    /// One transfer job waiting for room on a server. `count` is how many slots
    /// it needs, so a relay — which needs two — is admitted all-or-nothing.
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Jobs waiting for a slot, oldest first, per server.
    private var waiters: [ServerKey: [Waiter]] = [:]

    /// Slots promised but not yet backed by an open channel. A relay reserves both halves before
    /// opening either, so two concurrent relays can't each take one and deadlock.
    private var reserved: [ServerKey: Int] = [:]

    /// Six covers the widest case: 1 interactive + 1 background + 4 parallel folder-transfer streams,
    /// while staying under OpenSSH's default `MaxSessions` of 10 so one window can't exhaust a server.
    public init(maxPerServer: Int = 6) {
        self.maxPerServer = max(2, maxPerServer)
    }

    // MARK: Handing out channels

    /// The channel for this server and role, created on first use. `expected` is the pinned host-key
    /// fingerprint; a cached channel with different creds/pin is rebuilt, so fixes apply immediately.
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

        // A transfer that is part of an explicit reservation already holds its
        // slot; anything else claims one here and waits if the server is full.
        let claimsOwnSlot: Bool
        if case .transfer = role { claimsOwnSlot = (reserved[server] ?? 0) == 0 } else { claimsOwnSlot = false }
        if claimsOwnSlot { await awaitSlot(server, count: 1) }

        // `awaitSlot` suspends, so another task may have created this channel
        // while we waited. Re-check rather than orphaning the winner.
        if let existing = channels[key], existing.matches(target: target, expected: expected) {
            if claimsOwnSlot { releaseReserved(server, count: 1) }
            return existing
        }

        let created = SFTPSessionChannel(target: target, expected: expected)
        channels[key] = created
        // The channel now occupies the slot itself, so the reservation is spent — no waiter is
        // woken, since nothing was actually freed.
        if claimsOwnSlot { consumeReserved(server, count: 1) }
        return created
    }

    /// Claim `count` slots at once (both halves of a relay together — one at a time lets two relays
    /// deadlock holding one each). Every call must be balanced by ``release(_:count:)``.
    func reserve(_ target: SFTPTarget, count: Int) async {
        guard count > 0 else { return }
        await awaitSlot(ServerKey(target), count: count)
    }

    /// Give back slots taken by ``reserve(_:count:)``.
    func release(_ target: SFTPTarget, count: Int) {
        guard count > 0 else { return }
        releaseReserved(ServerKey(target), count: count)
    }

    /// Release a finished transfer job's connection and let the next job in.
    func releaseTransfer(_ id: UUID, target: SFTPTarget) {
        let server = ServerKey(target)
        let key = ChannelKey(server: server, role: .transfer(id))
        // Only a job that actually opened a channel frees a slot; waking a waiter for one that
        // never did (an intra-server move settled by a rename) would admit a connection past the cap.
        guard let channel = channels.removeValue(forKey: key) else { return }
        channel.shutdown()
        wakeWaiters(server)
    }

    /// Drop every connection to one server — on credential edit, pinned-key reset, or removal.
    /// The next operation reconnects with whatever is configured then.
    public func disconnectAll(matching target: SFTPTarget) {
        let server = ServerKey(target)
        for (key, channel) in channels where key.server == server {
            channel.shutdown()
            channels.removeValue(forKey: key)
        }
        wakeWaiters(server)
    }

    /// Close every connection this pool holds. For app teardown and tests.
    public func shutdownAll() {
        for channel in channels.values { channel.shutdown() }
        channels.removeAll()
        reserved.removeAll()
        // Abandoning a waiter's continuation would hang its task forever. Resuming without slots
        // is safe here because the pool is being torn down.
        for queue in waiters.values { for w in queue { w.continuation.resume() } }
        waiters.removeAll()
    }

    // MARK: Slot accounting

    /// Connections a server holds, counting slots promised but not yet opened —
    /// otherwise the same slot could be handed out twice.
    private func liveCount(_ server: ServerKey) -> Int {
        channels.keys.reduce(0) { $0 + ($1.server == server ? 1 : 0) }
            + (reserved[server] ?? 0)
    }

    private func awaitSlot(_ server: ServerKey, count: Int) async {
        // Admitted straight away only when nobody is already queued, so a
        // two-slot relay can't be starved by a stream of one-slot jobs behind it.
        if (waiters[server]?.isEmpty ?? true), liveCount(server) + count <= maxPerServer {
            reserved[server, default: 0] += count
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters[server, default: []].append(Waiter(count: count, continuation: cont))
        }
        // `wakeWaiters` charged the slots before resuming us, so nothing could
        // take them in the gap between that resume and this line.
    }

    /// Spend a reservation on a channel that now holds the slot itself. Nothing
    /// was freed, so no waiter is woken.
    private func consumeReserved(_ server: ServerKey, count: Int) {
        let remaining = (reserved[server] ?? 0) - count
        if remaining > 0 { reserved[server] = remaining } else { reserved.removeValue(forKey: server) }
    }

    /// Hand a reservation back and let whoever now fits through.
    private func releaseReserved(_ server: ServerKey, count: Int) {
        consumeReserved(server, count: count)
        wakeWaiters(server)
    }

    /// Admit as many queued waiters as now fit, oldest first, stopping at the first that doesn't —
    /// FIFO so a two-slot relay is never jumped indefinitely.
    private func wakeWaiters(_ server: ServerKey) {
        while let queue = waiters[server], let next = queue.first {
            guard liveCount(server) + next.count <= maxPerServer else { return }
            var rest = queue
            rest.removeFirst()
            if rest.isEmpty { waiters.removeValue(forKey: server) } else { waiters[server] = rest }
            // Charged before the resume, so the woken task's slots can't be taken
            // by anyone else while it is being scheduled.
            reserved[server, default: 0] += next.count
            next.continuation.resume()
        }
    }
}
