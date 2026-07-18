import Foundation
import GoelCore

/// The sidebar's live server-status pipeline: an unauthenticated reachability +
/// DNS refresh that runs on a timer for every saved server, and a lazy,
/// authenticated OS probe that piggy-backs on an already-open browser session.
///
/// The split matters for credentials: reachability/IP touch only the network
/// (TCP connect + DNS), so the periodic sweep never authenticates. OS detection
/// reuses the browser's live `SFTPClient` — so it only ever runs for a server the
/// user has *chosen* to browse, and never opens a fresh authenticated session on
/// its own.
@MainActor
extension AppViewModel {

    /// How often the sidebar re-checks reachability while the app is open.
    static var serverStatusRefreshSeconds: UInt64 { 20 }

    /// Probe every saved server's reachability + IP concurrently and fold the
    /// results into ``serverMeta``. Cheap and credential-free; safe to call on a
    /// timer and whenever the server list changes. OS info already detected is
    /// preserved.
    func refreshServerStatuses() async {
        let current = servers
        guard !current.isEmpty else {
            if !serverMeta.isEmpty { serverMeta = [:] }
            return
        }
        // Drop metadata for servers that no longer exist — but only republish when
        // there is actually a stale key, so a routine sweep doesn't re-render the
        // whole sidebar for nothing.
        let liveIDs = Set(current.map(\.id))
        if serverMeta.contains(where: { !liveIDs.contains($0.key) }) {
            serverMeta = serverMeta.filter { liveIDs.contains($0.key) }
        }

        // Probe every server concurrently, collect the raw results, then fold them
        // into `serverMeta` in a single assignment so one sweep = one @Published
        // change (not one per server, which would re-render the sidebar N times).
        var results: [SFTPConnection.ID: (reachable: Bool, latency: Int?, detail: String?, ip: String?)] = [:]
        await withTaskGroup(of: (SFTPConnection.ID, Bool, Int?, String?, String?).self) { group in
            for server in current {
                let id = server.id, host = server.host, port = server.port
                group.addTask {
                    async let probe = SFTPReachability.probe(host: host, port: port)
                    async let ip = SFTPReachability.resolveIP(host: host)
                    let (reachable, latency, detail) = await probe
                    return (id, reachable, latency, detail, await ip)
                }
            }
            for await (id, reachable, latency, detail, ip) in group {
                results[id] = (reachable, latency, detail, ip)
            }
        }

        // Merge into the *latest* `serverMeta` (a browser's OS detection may have
        // written during the awaits above) so we preserve `os` and the last good IP.
        var merged = serverMeta
        for (id, r) in results {
            var meta = merged[id] ?? ServerMeta()
            meta.reachability = r.reachable ? .online : .offline
            meta.latencyMS = r.latency
            meta.offlineDetail = r.reachable ? nil : r.detail
            if let ip = r.ip { meta.ip = ip }   // keep the last good resolution on a blip
            merged[id] = meta
        }
        if merged != serverMeta { serverMeta = merged }
    }

    /// Detect a server's OS the first time its browser opens, by reading
    /// `/etc/os-release` over the already-authenticated `client`. Best-effort and
    /// one-shot per server per session: a server that isn't Linux (or hides the
    /// file) simply keeps `os == nil` and shows no chip. Never opens its own
    /// connection — if `client` is nil the probe is skipped.
    func detectServerOSIfNeeded(_ connection: SFTPConnection, client: SFTPClient?) {
        guard let client, serverMeta[connection.id]?.os == nil,
              !osProbesInFlight.contains(connection.id) else { return }
        let id = connection.id
        osProbesInFlight.insert(id)   // guard against a duplicate probe on re-open
        Task { [weak self] in
            let os = await Self.readServerOS(using: client)
            await MainActor.run {
                guard let self else { return }
                self.osProbesInFlight.remove(id)
                guard let os else { return }
                var meta = self.serverMeta[id] ?? ServerMeta()
                meta.os = os
                self.serverMeta[id] = meta
            }
        }
    }

    /// Download `/etc/os-release` to a temp file, parse it, and clean up. Returns
    /// nil on any failure (file absent, non-Linux host, permission denied, or an
    /// over-cap response). The failure reason is logged, not surfaced.
    private static func readServerOS(using client: SFTPClient) async -> ServerOS? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-osrelease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A real /etc/os-release is well under a kilobyte. Cap the read so a
        // malicious or compromised server — this runs against a host the user is
        // browsing — can't stream unbounded data into the temp file / into memory.
        let cap = ByteCap(limit: 256 * 1024)
        do {
            try await client.downloadToFile(
                remote: "/etc/os-release", localURL: tmp,
                shouldContinue: { cap.underLimit }
            ) { sofar, total in cap.observe(sofar: sofar, total: total) }
            guard cap.underLimit else {
                ServerStatusLog.logger.debug("os-release exceeded size cap; skipping")
                return nil
            }
            let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            return ServerOS.parse(osRelease: text)
        } catch {
            ServerStatusLog.logger.debug("os-release read failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// A thread-safe byte-count guard for a bounded download: the progress callback
/// feeds it and `shouldContinue` reads it, so an over-cap transfer aborts on the
/// next tick. `@unchecked Sendable` — all access is serialised by the lock.
private final class ByteCap: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int64
    private var over = false
    init(limit: Int64) { self.limit = limit }
    func observe(sofar: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        if sofar > limit || total > limit { over = true }
    }
    var underLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return !over
    }
}
