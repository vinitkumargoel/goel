import Foundation

// MARK: - Platform side-effect ports

/// The three narrow `Sendable` seams that isolate ``DownloadManager`` from the
/// platform side-effects it drives: holding the system "prevent idle sleep" power
/// assertion, watching a folder for dropped `.torrent` files, and screening a
/// finished file with an external antivirus. The scheduler depends only on these
/// protocols, so its decision logic can be exercised with in-memory fakes; the
/// production adapters below wrap the existing concrete types verbatim and are wired
/// in by default, so nothing changes for the real app.

/// Drives the system "prevent idle sleep" power assertion and reports the current
/// power source. Mirrors the subset of ``PowerManager`` the scheduler uses.
public protocol PowerControlling: Sendable {
    func setPreventSleep(_ on: Bool)
    var isOnBattery: Bool { get }
}

/// Watches a directory for newly-appearing `.torrent` files. Mirrors the subset of
/// ``WatchFolderMonitor`` the scheduler uses.
public protocol FolderWatching: Sendable {
    func start(path: String, onNewTorrent: @escaping @Sendable (URL) -> Void) async
    func stop() async
}

/// Screens a finished file with an external command-line scanner, reporting whether
/// it passed. Mirrors the subset of ``AntivirusScanner`` the scheduler uses.
public protocol FileScanning: Sendable {
    func scan(path: String, executablePath: String, argumentTemplate: String) async -> Bool
}

// MARK: - Production adapters

/// Production ``PowerControlling`` backed by a live ``PowerManager``.
///
/// A `final class` — *not* a struct — because ``PowerManager/deinit`` releases the
/// outstanding IOKit assertion: the adapter must keep the single instance alive for
/// the manager's lifetime. A struct that copied-and-dropped the `PowerManager` would
/// let the keep-awake hold vanish the moment a copy went out of scope.
public final class SystemPowerControl: PowerControlling {
    private let manager: PowerManager

    public init(_ manager: PowerManager = PowerManager()) {
        self.manager = manager
    }

    public func setPreventSleep(_ on: Bool) { manager.setPreventSleep(on) }
    public var isOnBattery: Bool { manager.isOnBattery }
}

/// Production ``FolderWatching`` backed by a live ``WatchFolderMonitor``.
///
/// A `final class` for the same lifetime reason as ``SystemPowerControl``: the
/// monitor owns a running `DispatchSourceTimer` that its `deinit` cancels, so the
/// adapter must hold the single instance for the manager's lifetime rather than
/// dropping a struct copy out from under the live timer.
public final class SystemFolderWatch: FolderWatching {
    private let monitor: WatchFolderMonitor

    public init(_ monitor: WatchFolderMonitor = WatchFolderMonitor()) {
        self.monitor = monitor
    }

    public func start(path: String, onNewTorrent: @escaping @Sendable (URL) -> Void) async {
        await monitor.start(path: path, onNewTorrent: onNewTorrent)
    }

    public func stop() async {
        await monitor.stop()
    }
}

/// Production ``FileScanning`` forwarding to the stateless ``AntivirusScanner``.
/// A `struct` is fine here: the scanner owns no live resource to keep alive.
public struct ProcessFileScan: FileScanning {
    public init() {}

    public func scan(path: String, executablePath: String, argumentTemplate: String) async -> Bool {
        await AntivirusScanner.scan(
            path: path, executablePath: executablePath, argumentTemplate: argumentTemplate
        )
    }
}
