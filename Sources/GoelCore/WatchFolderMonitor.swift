import Foundation

/// Polls rather than using a vnode source, to survive browsers' write-then-rename; all state lives on `queue`.
public final class WatchFolderMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.goeldownloader.watchfolder")

    private var timer: DispatchSourceTimer?

    private var seen: Set<String> = []

    private var watchedPath: String?

    private var onNewTorrent: (@Sendable (URL) -> Void)?

    /// Edge-triggered: the timer fires every 2 s, so logging every failure emits one line per tick while the folder stays gone.
    private var lastScanFailed = false

    private let pollInterval: DispatchTimeInterval = .seconds(2)

    public init() {}

    deinit {
        timer?.cancel()
    }

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
