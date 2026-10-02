import Foundation
import GoelCore

/// How the SFTP browser orders a folder. Stored raw in `@AppStorage("sftp.browser.sortKey")`, so
/// the raw values are the ones older builds wrote.
enum SFTPBrowserSortKey: String, CaseIterable, Identifiable {
    case name
    case size
    case modified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return L10n.t("Name")
        case .size: return L10n.t("Size")
        case .modified: return L10n.t("Date Modified")
        }
    }
}

/// The browser's pure listing logic: which entries show, in what order, how the path reads as
/// breadcrumbs and how the footer counts them. No view state, so it is cheap to reason about.
enum SFTPBrowserListing {

    struct Crumb: Hashable {
        let label: String
        let path: String
    }

    /// Hidden files out unless asked for, then the filter, then folders first in the chosen order.
    static func visible(_ entries: [SFTPEntry], showHidden: Bool, filter: String,
                        sortKey: SFTPBrowserSortKey, ascending: Bool) -> [SFTPEntry] {
        var list = entries
        if !showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        return list.sorted { compare($0, $1, sortKey: sortKey, ascending: ascending) }
    }

    static func compare(_ a: SFTPEntry, _ b: SFTPEntry, sortKey: SFTPBrowserSortKey, ascending: Bool) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let byName = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        let inOrder: Bool
        switch sortKey {
        case .size:
            inOrder = a.size == b.size ? byName : a.size < b.size
        case .modified:
            let ad = a.modified ?? .distantPast, bd = b.modified ?? .distantPast
            inOrder = ad == bd ? byName : ad < bd
        case .name:
            inOrder = byName
        }
        return ascending ? inOrder : !inOrder
    }

    /// "Home" for the login folder, "/" for the root, then one crumb per path component.
    static func breadcrumbs(for path: String) -> [Crumb] {
        if path == "." || path.isEmpty { return [Crumb(label: L10n.t("Home"), path: ".")] }
        if path == "/" { return [Crumb(label: "/", path: "/")] }
        if path.hasPrefix("/") {
            var crumbs = [Crumb(label: "/", path: "/")]
            var acc = ""
            for part in path.split(separator: "/", omittingEmptySubsequences: true) {
                acc += "/" + part
                crumbs.append(Crumb(label: String(part), path: acc))
            }
            return crumbs
        }
        var crumbs = [Crumb(label: L10n.t("Home"), path: ".")]
        var acc = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            crumbs.append(Crumb(label: String(part), path: acc))
        }
        return crumbs
    }

    /// "5 folders · 6 files", or "Empty".
    static func itemSummary(_ entries: [SFTPEntry]) -> String {
        let folders = entries.filter(\.isDirectory).count
        let files = entries.count - folders
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? L10n.t("%d folder", folders) : L10n.t("%d folders", folders)) }
        if files > 0 { parts.append(files == 1 ? L10n.t("%d file", files) : L10n.t("%d files", files)) }
        return parts.isEmpty ? L10n.t("Empty") : parts.joined(separator: " · ")
    }

    /// The bytes the files add up to; a folder's listed size is its inode's, not its contents'.
    static func fileBytes(_ entries: [SFTPEntry]) -> Int64 {
        entries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
    }

    /// `sftp://user@host:port/path`, the form the address paste box and other clients accept.
    static func sftpLink(_ connection: SFTPConnection, remotePath: String) -> String {
        "sftp://\(connection.username)@\(connection.host):\(connection.port)"
            + (remotePath.hasPrefix("/") ? remotePath : "/" + remotePath)
    }
}
