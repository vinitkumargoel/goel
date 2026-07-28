import Foundation

// MARK: - Platform side-effect ports

/// The three narrow `Sendable` seams isolating ``DownloadManager`` from platform side-effects: idle-
/// sleep assertion, watch folder, antivirus. Fakeable in tests; production adapters below wrap the real types.

/// Drives the system "prevent idle sleep" power assertion and reports the current
/// power source. Mirrors the subset of ``PowerManager`` the scheduler uses.
public protocol PowerControlling: Sendable {
    func setPreventSleep(_ on: Bool)
    var isOnBattery: Bool { get }

    /// Remaining battery charge, 0…100, or `nil` with no battery / unreadable level. Backs the
    /// "pause below battery threshold" policy, which without it had no number to compare against.
    var batteryPercent: Int? { get }
}

public extension PowerControlling {
    /// A conformer that can't report a charge level reports none — automation then treats the machine
    /// as full and never pauses on battery level. Defaulted so existing conformers compile unchanged.
    var batteryPercent: Int? { nil }
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

/// Production ``PowerControlling`` backed by a live ``PowerManager``. A `final class`, not a struct:
/// ``PowerManager/deinit`` releases the IOKit assertion, so a dropped struct copy kills keep-awake.
public final class SystemPowerControl: PowerControlling {
    private let manager: PowerManager

    public init(_ manager: PowerManager = PowerManager()) {
        self.manager = manager
    }

    public func setPreventSleep(_ on: Bool) { manager.setPreventSleep(on) }
    public var isOnBattery: Bool { manager.isOnBattery }
    public var batteryPercent: Int? { manager.batteryPercent }
}

/// Production ``FolderWatching`` backed by a live ``WatchFolderMonitor``. A `final class` for the
/// same lifetime reason: its `deinit` cancels a live `DispatchSourceTimer` a struct copy would drop.
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
