import Foundation
import GoelCore

struct SFTPClipboard: Equatable {

    enum Operation: Equatable {
        case copy
        case cut
    }

    let operation: Operation
    let connectionID: UUID
    let directory: String
    let items: [SFTPEntry]

    var isEmpty: Bool { items.isEmpty }

    func sourcePath(_ entry: SFTPEntry) -> String {
        SFTPBrowserPaths.join(directory, entry.name)
    }

    var pasteLabel: String {
        if items.count == 1 { return L10n.t("Paste “%@”", items[0].name) }
        return L10n.t("Paste %d Items", items.count)
    }

    func isSelfMove(toConnection id: UUID, directory target: String) -> Bool {
        operation == .cut && id == connectionID && target == directory
    }

    /// Copying a folder into itself never terminates on a recursive walk.
    func wouldRecurse(_ entry: SFTPEntry, intoConnection id: UUID, directory target: String) -> Bool {
        guard entry.isDirectory, id == connectionID else { return false }
        let source = sourcePath(entry)
        return target == source || target.hasPrefix(source + "/")
    }
}
