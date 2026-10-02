import Foundation
import GoelCore

/// Counts behind the rail's "Transfers" row: what is moving, and what needs a look.
struct SFTPTransferSummary: Equatable {
    var active = 0
    var failed = 0
    var total = 0

    init(_ transfers: [SFTPTransfer]) {
        for transfer in transfers {
            total += 1
            if transfer.isActive { active += 1 }
            if case .failed = transfer.state { failed += 1 }
        }
    }
}
