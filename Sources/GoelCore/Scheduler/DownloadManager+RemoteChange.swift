import Foundation

extension DownloadManager {

    static let remoteChangeInterval: UInt64 = 6 * 60 * 60
    static let remoteChangeInitialDelay: UInt64 = 120

    func updateRedownloadSchedule() {
        redownloadTask?.cancel()
        redownloadTask = nil
        guard settings.autoRedownloadOnRemoteChange else { return }
        redownloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.remoteChangeInitialDelay * 1_000_000_000)
            while !Task.isCancelled {
                await self?.sweepFinishedForRemoteChanges()
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: Self.remoteChangeInterval * 1_000_000_000)
            }
        }
    }

    func sweepFinishedForRemoteChanges() async {
        // Each probe awaits, so these are a snapshot — re-resolve by id before mutating.
        let candidates = tasks.filter {
            $0.status == .completed && $0.kind == .http
        }
        guard !candidates.isEmpty else { return }

        // Must honour the user's proxy, or the sweep leaks their real IP.
        let proxy = Self.proxyDictionary(from: settings)
        for candidate in candidates {
            guard case .url(let url) = candidate.source else { continue }
            guard let validators = await Self.fetchValidators(url: url,
                                                              userAgent: settings.userAgent,
                                                              proxy: proxy) else { continue }
            let changed = Self.remoteResourceChanged(
                oldETag: candidate.remoteInfo?.etag, oldSize: candidate.totalBytes,
                newETag: validators.etag, newSize: validators.size)
            guard changed else { continue }
            guard let i = index(of: candidate.id),
                  tasks[i].status == .completed,
                  tasks[i].remoteInfo?.etag == candidate.remoteInfo?.etag,
                  tasks[i].totalBytes == candidate.totalBytes else { continue }
            requeueForRedownload(at: i)
        }
    }

    /// Must clear the resume cursor, else the refetch resumes against the changed bytes.
    private func requeueForRedownload(at i: Int) {
        tasks[i].status = .queued
        tasks[i].bytesDownloaded = 0
        tasks[i].downloadSpeed = 0
        tasks[i].resumeData = nil
        tasks[i].completedAt = nil
        tasks[i].scanVerdict = nil
        // A stale mark holds the OLD size, so StatsAccumulator would report deltaDown == 0 and lose the run.
        statsMarks[tasks[i].id] = nil
        speedMeters[tasks[i].id] = nil
        persist(tasks[i])
        publish()
        schedule()
    }

    /// A missing side is "unknown" → not changed, so a dropped validator never triggers a re-download.
    static func remoteResourceChanged(oldETag: String?, oldSize: Int64?,
                                      newETag: String?, newSize: Int64?) -> Bool {
        if let o = oldETag, let n = newETag, !o.isEmpty, !n.isEmpty {
            return o != n
        }
        if let o = oldSize, let n = newSize, o > 0, n > 0 {
            return o != n
        }
        return false
    }

    struct RemoteValidators: Sendable { var etag: String?; var size: Int64? }

    static func fetchValidators(url: URL, userAgent: String,
                                proxy: [String: Any]?) async -> RemoteValidators? {
        let session = SessionPool.session(key: "validators/" + SessionPool.proxyKey(proxy)) {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = proxy
            return URLSession(configuration: config)
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let size = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        return RemoteValidators(etag: etag, size: size)
    }

    static func proxySpec(from settings: AppSettings) -> NetworkGuard.ProxySpec {
        NetworkGuard.ProxySpec(mode: settings.proxyMode, type: settings.proxyType,
                               host: settings.proxyHost, port: settings.proxyPort)
    }

    /// Mirrors the HTTP engine's handling so background probes never bypass the user's proxy.
    static func proxyDictionary(from settings: AppSettings) -> [String: Any]? {
        NetworkGuard.proxyDictionary(proxySpec(from: settings))
    }
}
