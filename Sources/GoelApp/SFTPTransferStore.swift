import Foundation
import Combine

/// The SFTP transfer rows, apart from `AppViewModel`. Progress callbacks land here ~10×/s per
/// transfer; only a row appearing, leaving or changing state is announced at once — byte counts
/// are announced on the next speed-sampler tick, so ten transfers no longer mean 100 redraws/s.
@MainActor
final class SFTPTransferStore: ObservableObject {

    private var storage: [SFTPTransfer] = []
    private(set) var hasUnannouncedProgress = false

    var transfers: [SFTPTransfer] {
        get { storage }
        set {
            if Self.isStructuralChange(from: storage, to: newValue) {
                objectWillChange.send()
                hasUnannouncedProgress = false
            } else {
                hasUnannouncedProgress = true
            }
            storage = newValue
        }
    }

    /// Called from the sampler tick: announces whatever progress piled up since the last one.
    func flushProgress() {
        guard hasUnannouncedProgress else { return }
        hasUnannouncedProgress = false
        objectWillChange.send()
    }

    static func isStructuralChange(from old: [SFTPTransfer], to new: [SFTPTransfer]) -> Bool {
        guard old.count == new.count else { return true }
        for (a, b) in zip(old, new) where a.id != b.id || a.state != b.state || a.name != b.name {
            return true
        }
        return false
    }
}
