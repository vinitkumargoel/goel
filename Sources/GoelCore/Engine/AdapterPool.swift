import Foundation

actor AdapterPool {
    private let adapters: [BoundAdapter]
    private var demoted: Set<String> = []

    init(_ adapters: [BoundAdapter]) {
        self.adapters = adapters
    }

    var usableCount: Int {
        let live = adapters.filter { !demoted.contains($0.bsdName) }
        return live.isEmpty ? 0 : live.count
    }

    /// If everything is demoted, clear the slate once so the pool never goes empty mid-download.
    func assign(segment index: Int) -> BoundAdapter? {
        var live = adapters.filter { !demoted.contains($0.bsdName) }
        if live.isEmpty {
            demoted.removeAll()
            live = adapters
        }
        guard !live.isEmpty else { return nil }
        return live[index % live.count]
    }

    func demote(_ bsdName: String) {
        demoted.insert(bsdName)
    }

    func demote(_ adapter: BoundAdapter) {
        demoted.insert(adapter.bsdName)
    }
}

/// Written from curl's callback on any thread — the `@unchecked Sendable` holds only because of the lock.
final class ByteTally: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0

    func add(_ n: Int) {
        lock.lock(); pending += n; lock.unlock()
    }

    func drain() -> Int {
        lock.lock()
        let n = pending
        pending = 0
        lock.unlock()
        return n
    }
}
