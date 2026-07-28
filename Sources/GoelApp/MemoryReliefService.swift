import Foundation
import Darwin

final class MemoryReliefService {

    private var pressureSource: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "com.goel.downloader.memory-relief", qos: .utility)

    func start() {
        pressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: queue)
        source.setEventHandler { [weak self] in self?.reclaim() }
        source.resume()
        pressureSource = source
    }

    func reclaim() {
        malloc_zone_pressure_relief(nil, 0)
    }

    func reclaimAsync() {
        queue.async { [weak self] in self?.reclaim() }
    }

    deinit { pressureSource?.cancel() }
}
