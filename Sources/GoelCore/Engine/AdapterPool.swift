import Foundation

/// Assigns network adapters to HTTP segments (round-robin) and demotes flaky
/// ones — mirrors ``MirrorPool`` but for egress interfaces.
///
/// Weighted rebalance is intentionally **not** here: ``ConnectionGovernor`` is
/// monotonic-decreasing; adaptive weights are a separate Phase‑3 mechanism.
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

    /// Round-robin among non-demoted adapters. If everything is demoted, clears
    /// the slate once so the pool never goes empty mid-download.
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
