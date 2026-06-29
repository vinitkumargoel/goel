import Foundation

/// Watches a directory for newly-appearing `.torrent` files and reports each one
/// exactly once.
///
/// Backs the Settings › BitTorrent "watch folder" option: while enabled, dropping
/// a `.torrent` into the configured folder hands its URL to `onNewTorrent` so the
/// manager can add it as a download. A lightweight polling `DispatchSourceTimer`
/// is used rather than a vnode source — polling survives the atomic write-then-
/// rename pattern browsers use when saving files, and never misses a file because
/// a directory file descriptor went momentarily stale. Files already present when
/// the watch starts count as newly-appearing (so a `.torrent` dropped while the
/// app was closed is still picked up); each path is reported only once per watch.
/// All mutable state is touched only inside `queue` blocks, so the type is safe to
/// hand across isolation boundaries (it is held by the `DownloadManager` actor and
/// captured in the queue's `@Sendable` closures).
public final class WatchFolderMonitor: @unchecked Sendable {
    /// Serializes all state access and timer callbacks.
    private let queue = DispatchQueue(label: "com.goeldownloader.watchfolder")

    /// Rescans the directory on a fixed cadence while a watch is active.
    private var timer: DispatchSourceTimer?

    /// Standardized paths of `.torrent` files already handed to the callback.
    private var seen: Set<String> = []

    /// The directory currently being watched, or `nil` when stopped.
    private var watchedPath: String?

    /// Invoked once per newly-discovered `.torrent` file.
    private var onNewTorrent: (@Sendable (URL) -> Void)?

    /// How often the watched directory is rescanned.
    private let pollInterval: DispatchTimeInterval = .seconds(2)

    public init() {}

    deinit {
        timer?.cancel()
    }

    /// Begin watching `path`, replacing any folder watched previously.
    ///
    /// Every `.torrent` found that has not been reported yet — including files
    /// already present when watching starts — is passed to `onNewTorrent`. The
    /// callback runs on a private serial queue, so it must be safe to invoke off
    /// the main thread.
    /// `async` so a caller on a Swift actor (the `DownloadManager`) *suspends*
    /// rather than blocking its cooperative thread while the private queue — which
    /// may be mid-`scan()` on a slow network share — hands over. Re-starting for the
    /// same path preserves the seen-set, so an unrelated settings change does not
    /// re-report files already handed to the callback.
    public func start(path: String, onNewTorrent: @escaping @Sendable (URL) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                self.timer?.cancel()
                self.timer = nil
                if self.watchedPath != path { self.seen.removeAll() }
                self.watchedPath = path
                self.onNewTorrent = onNewTorrent

                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: self.pollInterval)
                timer.setEventHandler { [weak self] in
                    self?.scan()
                }
                self.timer = timer
                timer.resume()
                cont.resume()
            }
        }
    }

    /// Stop watching and tear down all state. `async` for the same non-blocking
    /// reason as ``start(path:onNewTorrent:)``. Safe to call when not running.
    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.timer?.cancel()
                self?.timer = nil
                self?.watchedPath = nil
                self?.onNewTorrent = nil
                self?.seen.removeAll()
                cont.resume()
            }
        }
    }

    /// Diff the watched directory and report any `.torrent` file not seen yet.
    /// Always runs on `queue`.
    private func scan() {
        guard let path = watchedPath, let callback = onNewTorrent else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in contents where url.pathExtension.lowercased() == "torrent" {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            callback(url)
        }
    }
}
