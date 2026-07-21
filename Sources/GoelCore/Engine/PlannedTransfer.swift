import Foundation

// MARK: - Planned transfer

/// Plan + transfer pair resolved after probe + budget segment resolution.
///
/// ``HTTPEngine/run`` sequence: probe → budget.resolve → build ``TransferPlan`` →
/// ``PlannedTransfer`` → budget.reserve(`connectionCount`) → run. Keeps plan
/// construction on the engine (needs session / credentials / aggregation) while
/// exposing the fan-out the budget must charge before byte pumps start.
struct PlannedTransfer: Sendable {
    let plan: TransferPlan
    let transfer: SegmentedTransfer

    /// Connections the transfer will actually open (resume may differ from the
    /// freshly-resolved ``TransferPlan/segmentCount``).
    var connectionCount: Int { transfer.connectionCount }

    /// Live progress ticks; finishes when ``run()`` returns or throws.
    var progress: AsyncStream<TransferProgress> { transfer.progress }

    init(plan: TransferPlan) {
        self.plan = plan
        self.transfer = SegmentedTransfer(plan: plan)
    }

    /// Run the transfer to completion (segmented or single-stream per plan).
    func run() async throws -> TransferOutcome {
        try await transfer.run()
    }
}
