import Foundation
import GoelCore

/// The Add sheet's "Needs 48 GB · 12 GB free" line. The engines only check free space once a
/// download is running, and then only for HTTP; this warns before anything is queued.
enum DiskSpaceCheck {

    struct Verdict: Equatable {
        let needed: Int64
        let available: Int64
        var isSufficient: Bool { needed <= available }
    }

    static func verdict(needed: Int64?, available: Int64?) -> Verdict? {
        guard let needed, needed > 0, let available, available >= 0 else { return nil }
        return Verdict(needed: needed, available: available)
    }

    static func message(for verdict: Verdict) -> String {
        L10n.t("Needs %1$@ · %2$@ free", verdict.needed.byteString, verdict.available.byteString)
    }

    static func spokenMessage(for verdict: Verdict) -> String {
        verdict.isSufficient
            ? L10n.t("Needs %1$@, %2$@ free", A11y.bytes(verdict.needed), A11y.bytes(verdict.available))
            : L10n.t("Not enough space. Needs %1$@, only %2$@ free", A11y.bytes(verdict.needed), A11y.bytes(verdict.available))
    }

    /// Free bytes on the volume holding `path`, as Finder reports it (purgeable space counts).
    /// The folder may not exist yet — downloads create it — so the nearest existing ancestor is asked.
    static func availableCapacity(forFolder path: String) -> Int64? {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let fm = FileManager.default
        while !fm.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                      .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
