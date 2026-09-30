import Foundation

public protocol PowerControlling: Sendable {
    func setPreventSleep(_ on: Bool)
    var isOnBattery: Bool { get }

    var batteryPercent: Int? { get }
}

public extension PowerControlling {
    var batteryPercent: Int? { nil }
}

public protocol FolderWatching: Sendable {
    func start(path: String, onNewTorrent: @escaping @Sendable (URL) -> Void) async
    func stop() async
}

/// A scanner that couldn't run (timeout, launch failure, killed) is not a detection: collapsing the two
/// made every download look infected whenever the scanner broke.
public enum ScanResult: Sendable, Equatable {
    case clean
    case infected
    case error(String)
}

public protocol FileScanning: Sendable {
    func scan(path: String, executablePath: String, argumentTemplate: String) async -> ScanResult
}

/// A class, not a struct: `PowerManager.deinit` releases the IOKit assertion, so a dropped copy kills keep-awake.
public final class SystemPowerControl: PowerControlling {
    private let manager: PowerManager

    public init(_ manager: PowerManager = PowerManager()) {
        self.manager = manager
    }

    public func setPreventSleep(_ on: Bool) { manager.setPreventSleep(on) }
    public var isOnBattery: Bool { manager.isOnBattery }
    public var batteryPercent: Int? { manager.batteryPercent }
}

/// A class for the same reason: its `deinit` cancels a `DispatchSourceTimer` a struct copy would drop.
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

public struct ProcessFileScan: FileScanning {
    public init() {}

    public func scan(path: String, executablePath: String, argumentTemplate: String) async -> ScanResult {
        await AntivirusScanner.scan(
            path: path, executablePath: executablePath, argumentTemplate: argumentTemplate
        )
    }
}
