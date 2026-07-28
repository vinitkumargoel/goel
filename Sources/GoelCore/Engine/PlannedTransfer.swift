import Foundation

struct PlannedTransfer: Sendable {
    let plan: TransferPlan
    let transfer: SegmentedTransfer

    var connectionCount: Int { transfer.connectionCount }

    var progress: AsyncStream<TransferProgress> { transfer.progress }

    init(plan: TransferPlan) {
        self.plan = plan
        self.transfer = SegmentedTransfer(plan: plan)
    }

    func run() async throws -> TransferOutcome {
        try await transfer.run()
    }
}
