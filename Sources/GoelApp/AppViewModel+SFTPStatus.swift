import Foundation
import GoelCore

@MainActor
extension AppViewModel {

    static var serverStatusRefreshSeconds: UInt64 { 20 }

    func refreshServerStatuses() async {
        let current = servers
        guard !current.isEmpty else {
            if !serverMeta.isEmpty { serverMeta = [:] }
            return
        }
        let liveIDs = Set(current.map(\.id))
        if serverMeta.contains(where: { !liveIDs.contains($0.key) }) {
            serverMeta = serverMeta.filter { liveIDs.contains($0.key) }
        }

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

        // Re-read `serverMeta` after the awaits: an OS probe may have written to it meanwhile.
        var merged = serverMeta
        for (id, r) in results {
            var meta = merged[id] ?? ServerMeta()
            meta.reachability = r.reachable ? .online : .offline
            meta.latencyMS = r.latency
            meta.offlineDetail = r.reachable ? nil : r.detail
            if let ip = r.ip { meta.ip = ip }
            merged[id] = meta
        }
        if merged != serverMeta { serverMeta = merged }
    }

    func detectServerOSIfNeeded(_ connection: SFTPConnection, client: SFTPClient?) {
        guard let client, serverMeta[connection.id]?.os == nil,
              !osProbesInFlight.contains(connection.id) else { return }
        let id = connection.id
        osProbesInFlight.insert(id)
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

    private static func readServerOS(using client: SFTPClient) async -> ServerOS? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-osrelease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Cap the read: a hostile server must not stream unbounded data into temp/memory.
        let cap = ByteCap(limit: 256 * 1024)
        do {
            try await client.downloadToFile(
                remote: "/etc/os-release", localURL: tmp,
                shouldContinue: { cap.underLimit }
            ) { sofar, total in cap.observe(sofar: sofar, total: total) }
            guard cap.underLimit else {
                GoelLog.app.debug("os-release exceeded size cap; skipping")
                return nil
            }
            let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            return ServerOS.parse(osRelease: text)
        } catch {
            GoelLog.app.debug("os-release read failed", .detail(String(describing: error)))
            return nil
        }
    }
}

/// Bounds any download whose size is server-supplied; aborts on the next progress tick.
final class ByteCap: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int64
    private var over = false
    init(limit: Int64) { self.limit = limit }
    /// Checks `total` as well as `sofar` so an over-cap transfer dies on the first tick.
    func observe(sofar: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        if sofar > limit || total > limit { over = true }
    }
    var underLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return !over
    }
}
