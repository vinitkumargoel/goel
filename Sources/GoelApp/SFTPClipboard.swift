import Foundation
import GoelCore

/// What the user copied or cut in a remote browser, waiting to be pasted. App-internal, not
/// `NSPasteboard`: a bare path string would let a paste land with no idea which server it means.
struct SFTPClipboard: Equatable {

    enum Operation: Equatable {
        /// ⌘C — the source stays where it is.
        case copy
        /// ⌘X — the source is removed once the destination has the bytes. A cut only takes effect on
        /// paste, so an un-pasted cut leaves everything as it was.
        case cut
    }

    let operation: Operation
    let connectionID: UUID
    /// The directory the items were copied from, so their absolute paths can be
    /// rebuilt without depending on where the browser has navigated since.
    let directory: String
    let items: [SFTPEntry]

    var isEmpty: Bool { items.isEmpty }

    /// The absolute remote path of one clipboard item.
    func sourcePath(_ entry: SFTPEntry) -> String {
        SFTPBrowserPaths.join(directory, entry.name)
    }

    /// A label for the paste menu item — "Paste 3 Items", Finder-style.
    var pasteLabel: String {
        if items.count == 1 { return "Paste “\(items[0].name)”" }
        return "Paste \(items.count) Items"
    }

    /// Whether pasting into `directory` on `connection` would be a no-op move —
    /// cutting items and pasting them back where they came from.
    func isSelfMove(toConnection id: UUID, directory target: String) -> Bool {
        operation == .cut && id == connectionID && target == directory
    }

    /// Whether pasting `entry` into `target` would copy a folder into itself,
    /// which on a recursive walk never terminates.
    func wouldRecurse(_ entry: SFTPEntry, intoConnection id: UUID, directory target: String) -> Bool {
        guard entry.isDirectory, id == connectionID else { return false }
        let source = sourcePath(entry)
        return target == source || target.hasPrefix(source + "/")
    }
}
