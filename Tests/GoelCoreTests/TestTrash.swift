import Foundation
@testable import GoelCore

/// Engines move deleted files to the Trash. A test run must never fill the developer's real
/// ~/.Trash, so suites that exercise "remove and delete" swap the seam for a plain unlink.
enum TestTrash {
    /// Installs the fake and returns the closure that restores the production seam.
    static func install() -> () -> Void {
        #if os(macOS)
        let original = RemoteTransferPrep.trashItem
        RemoteTransferPrep.trashItem = { try FileManager.default.removeItem(at: $0) }
        return { RemoteTransferPrep.trashItem = original }
        #else
        return {}
        #endif
    }
}
