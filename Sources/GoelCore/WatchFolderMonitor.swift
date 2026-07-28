import Foundation

/// Reports each newly-appearing `.torrent` in the Settings › BitTorrent watch folder exactly once.
/// Polls (not a vnode source) to survive browsers' write-then-rename; all state lives inside `queue`.
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

    /// Whether the last scan could not read the directory. Edge-triggered: the timer fires every 2 s,
    /// so logging every failure would emit one line per tick for as long as the folder stays gone.
    private var lastScanFailed = false

    /// How often the watched directory is rescanned.
    private let pollInterval: DispatchTimeInterval = .seconds(2)

    public init() {}

    deinit {
        timer?.cancel()
    }

    /// Watch `path`, reporting every unseen `.torrent` (including pre-existing ones) to `onNewTorrent`
    /// off the main thread. `async` so an actor caller suspends, not blocks; same path keeps the seen-set.
    public func start(path: String, onNewTorrent: @escaping @Sendable (URL) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                self.timer?.cancel()
                self.timer = nil
                if self.watchedPath != path { self.seen.removeAll() }
                self.watchedPath = path
                self.onNewTorrent = onNewTorrent
                self.lastScanFailed = false

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
                self?.lastScanFailed = false
                cont.resume()
            }
        }
    }

    /// Diff the watched directory for unseen `.torrent` files; always on `queue`. An unreadable folder
    /// once looked identical to an empty one, so log edge-triggered and keep the timer to self-recover.
    private func scan() {
        guard let path = watchedPath, let callback = onNewTorrent else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            lastScanFailed = false
        } catch {
            if !lastScanFailed {
                lastScanFailed = true
                GoelLog.scheduler.error("Watch folder unreadable", .path(path))
            }
            return
        }

        for url in contents where url.pathExtension.lowercased() == "torrent" {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            callback(url)
        }
    }
}
