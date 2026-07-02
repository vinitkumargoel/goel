import Foundation

// MARK: - Auto re-download on remote change

/// An opt-in background check that re-downloads a *finished* HTTP download when
/// its remote resource changes. A completed task keeps the server's validators
/// (`ETag` via ``DownloadTask/remoteInfo`` and the byte size via
/// ``DownloadTask/totalBytes``); on a coarse timer we issue a cheap `HEAD` and,
/// when a validator has definitively changed, re-queue the task so the engine
/// fetches the new version (overwriting the old file).
///
/// Deliberately conservative: it acts ONLY on a proven difference (never on a
/// missing/transient validator), only for completed HTTP downloads, and only
/// while ``AppSettings/autoRedownloadOnRemoteChange`` is enabled — so a finished
/// file is never silently replaced by accident.
extension DownloadManager {

    /// Seconds between remote-change sweeps (6 hours).
    static let remoteChangeInterval: UInt64 = 6 * 60 * 60
    /// Delay before the first sweep after arming (2 minutes) so launch isn't noisy.
    static let remoteChangeInitialDelay: UInt64 = 120

    /// (Re)arm the remote-change sweep when the setting is on; tear it down when off.
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

    /// HEAD every completed HTTP download and re-queue the ones whose remote
    /// resource changed. Best-effort — a failed probe leaves the task untouched.
    func sweepFinishedForRemoteChanges() async {
        // Snapshot the candidates up front; each probe awaits, so re-resolve by id
        // before mutating (the user may have removed/changed a task meanwhile).
        let candidates = tasks.filter {
            $0.status == .completed && $0.kind == .http
        }
        guard !candidates.isEmpty else { return }

        // Build the probe session once, honouring the user's manual/SOCKS proxy so
        // the sweep never leaks the real IP of someone who configured a proxy.
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
            // Re-resolve: the task must still be the same completed download.
            guard let i = index(of: candidate.id),
                  tasks[i].status == .completed,
                  tasks[i].remoteInfo?.etag == candidate.remoteInfo?.etag,
                  tasks[i].totalBytes == candidate.totalBytes else { continue }
            requeueForRedownload(at: i)
        }
    }

    /// Reset a completed task back to `.queued` for a fresh fetch (the engine
    /// re-probes and overwrites the old file). Clears the resume cursor so it
    /// starts from zero rather than trying to resume against changed bytes.
    private func requeueForRedownload(at i: Int) {
        tasks[i].status = .queued
        tasks[i].bytesDownloaded = 0
        tasks[i].downloadSpeed = 0
        tasks[i].resumeData = nil
        tasks[i].completedAt = nil
        tasks[i].scanVerdict = nil
        persist(tasks[i])
        publish()
        schedule()
    }

    /// Pure decision: has a validator definitively changed? Prefers `ETag` (both
    /// present, non-empty, and different); falls back to byte size. Any missing
    /// side is treated as "unknown" → not changed, so we never re-download on a
    /// server that simply stopped sending a validator.
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

    /// The remote validators from a cheap `HEAD`, or nil if the probe failed. The
    /// `proxy` dictionary (from ``proxyDictionary(from:)``) is applied so the probe
    /// follows the same proxy policy as real downloads.
    struct RemoteValidators: Sendable { var etag: String?; var size: Int64? }

    static func fetchValidators(url: URL, userAgent: String,
                                proxy: [String: Any]?) async -> RemoteValidators? {
        let config = URLSessionConfiguration.ephemeral
        // nil ⇒ follow the OS proxy (system); [:] ⇒ explicit direct; populated ⇒
        // route through the configured manual/SOCKS proxy.
        config.connectionProxyDictionary = proxy
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
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

    /// A `Sendable` snapshot of the user's proxy settings, for handing across
    /// actor boundaries (e.g. into the torrent engine's `.torrent`-file fetch).
    static func proxySpec(from settings: AppSettings) -> NetworkGuard.ProxySpec {
        NetworkGuard.ProxySpec(mode: settings.proxyMode, type: settings.proxyType,
                               host: settings.proxyHost, port: settings.proxyPort)
    }

    /// Translate the user's proxy settings into a `connectionProxyDictionary`:
    /// nil to follow the OS ("system"), an empty dict to force direct ("none"),
    /// or the HTTP/SOCKS keys for a configured manual proxy. Mirrors the HTTP
    /// engine's own proxy handling so background probes don't bypass it.
    static func proxyDictionary(from settings: AppSettings) -> [String: Any]? {
        NetworkGuard.proxyDictionary(proxySpec(from: settings))
    }
}
