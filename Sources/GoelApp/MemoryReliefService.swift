import Foundation
import Darwin

/// Returns already-freed heap pages to the OS via `malloc_zone_pressure_relief`, which macOS
/// otherwise keeps as resident slack. Non-destructive; fired on memory pressure and on losing focus.
final class MemoryReliefService {

    private var pressureSource: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "com.goel.downloader.memory-relief", qos: .utility)

    /// Begin listening for system memory-pressure events. Idempotent — a second
    /// call replaces the existing source.
    func start() {
        pressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: queue)
        source.setEventHandler { [weak self] in self?.reclaim() }
        source.resume()
        pressureSource = source
    }

    /// Hand freed pages back to the OS. Safe to call from any thread and as often
    /// as you like; when there is nothing to release it is a cheap no-op.
    func reclaim() {
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Schedule a reclaim off the caller's thread — used by lifecycle hooks that
    /// fire on the main actor (e.g. losing focus) so the walk never blocks the UI.
    func reclaimAsync() {
        queue.async { [weak self] in self?.reclaim() }
    }

    deinit { pressureSource?.cancel() }
}
