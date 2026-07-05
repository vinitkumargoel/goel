import Foundation
import Darwin

/// Returns already-freed heap pages to the OS instead of letting the allocator
/// hold them as reclaimable-but-resident slack.
///
/// macOS's `malloc` keeps freed pages on a per-zone free list rather than
/// unmapping them immediately — cheap for the next allocation, but after a large
/// transient (a big transfer, a directory walk, a burst of parsing) it leaves the
/// process's resident footprint inflated long after the data is gone. This is the
/// gap between "live heap" and "dirty malloc regions" you see in `footprint`.
///
/// `malloc_zone_pressure_relief(nil, 0)` walks every zone and hands the free pages
/// back. It is **non-destructive**: it never touches live allocations, only pages
/// that are already free — so the worst case is that a future allocation re-faults
/// a page. We trigger it on two occasions where the trade always favours giving
/// memory back:
///   • the OS raising memory pressure (warning/critical), and
///   • the app losing focus (the user switched away — latency no longer matters).
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
