import Foundation
import GoelCore

/// One file as the tree sees it: the torrent's relative path, sizes, and whether it is wanted.
struct FileTreeItem: Identifiable, Equatable, Sendable {
    let id: Int
    let path: String
    let size: Int64
    var done: Int64 = 0

    var name: String { (path as NSString).lastPathComponent }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    init(id: Int, path: String, size: Int64, done: Int64 = 0) {
        self.id = id
        self.path = path
        self.size = size
        self.done = done
    }

    init(_ file: TransferFile) {
        self.init(id: file.id, path: file.path, size: file.length, done: file.bytesCompleted)
    }
}

/// A folder or file in the tree, with per-folder totals rolled up from its files.
struct FileTreeNode: Identifiable, Equatable, Sendable {
    /// The folder's path, or the file's path; unique within one tree.
    let id: String
    let name: String
    var children: [FileTreeNode]
    /// Set for a file, nil for a folder.
    let fileID: Int?
    var size: Int64
    var done: Int64
    /// Every file id at or below this node, so tri-state checks are one set comparison.
    var fileIDs: [Int]

    var isFolder: Bool { fileID == nil }
    var fraction: Double { size > 0 ? min(1, Double(done) / Double(size)) : 0 }
}

enum FileCheckState: Equatable, Sendable {
    case on, off, mixed
}

/// The quick selections offered in the tree's "Select ▸" menu.
enum FileSelectionPreset: Equatable, Sendable {
    case all
    case none
    case onlyVideo
    case byExtension(String)
}

enum FileTree {

    static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "webm", "m4v", "flv", "wmv", "ts", "m2ts"]

    /// Builds folders from the paths' components. Folders sort before files, both by name.
    static func build(_ items: [FileTreeItem]) -> [FileTreeNode] {
        let root = Builder()
        for item in items {
            let parts = item.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            root.insert(item, parts: parts[...], prefix: "")
        }
        return root.nodes()
    }

    static func state(of node: FileTreeNode, wanted: Set<Int>) -> FileCheckState {
        let ids = node.fileIDs
        guard !ids.isEmpty else { return .off }
        let count = ids.reduce(0) { $0 + (wanted.contains($1) ? 1 : 0) }
        if count == 0 { return .off }
        return count == ids.count ? .on : .mixed
    }

    /// Clicking a mixed or empty box selects everything under it; clicking a full one clears it.
    static func toggling(_ node: FileTreeNode, in wanted: Set<Int>) -> Set<Int> {
        if state(of: node, wanted: wanted) == .on {
            return wanted.subtracting(node.fileIDs)
        }
        return wanted.union(node.fileIDs)
    }

    static func applying(_ preset: FileSelectionPreset, to items: [FileTreeItem]) -> Set<Int> {
        switch preset {
        case .all:
            return Set(items.map(\.id))
        case .none:
            return []
        case .onlyVideo:
            return Set(items.filter { videoExtensions.contains($0.fileExtension) }.map(\.id))
        case .byExtension(let ext):
            let wantedExt = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return Set(items.filter { $0.fileExtension == wantedExt }.map(\.id))
        }
    }

    /// Extensions present, most common first, for the "By extension" submenu.
    static func extensionCounts(_ items: [FileTreeItem]) -> [(ext: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items where !item.fileExtension.isEmpty {
            counts[item.fileExtension, default: 0] += 1
        }
        return counts.map { (ext: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.ext < $1.ext }
    }

    /// Keeps files whose path contains `query` (case-insensitive) and the folders leading to them.
    static func filtered(_ nodes: [FileTreeNode], query: String) -> [FileTreeNode] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nodes }
        return nodes.compactMap { filtered($0, needle: needle) }
    }

    private static func filtered(_ node: FileTreeNode, needle: String) -> FileTreeNode? {
        if !node.isFolder {
            return node.id.lowercased().contains(needle) ? node : nil
        }
        let kids = node.children.compactMap { filtered($0, needle: needle) }
        guard !kids.isEmpty else { return nil }
        // Everything a folder row reports must come from what the filter kept: a hidden file must
        // neither be toggled by the folder's checkbox nor count toward its tri-state or totals.
        var copy = node
        copy.children = kids
        copy.fileIDs = kids.flatMap(\.fileIDs)
        copy.size = kids.reduce(Int64(0)) { $0 + $1.size }
        copy.done = kids.reduce(Int64(0)) { $0 + $1.done }
        return copy
    }

    /// A visible row: the node plus its depth, for a flat, cheap-to-diff list.
    struct Row: Identifiable, Equatable {
        let node: FileTreeNode
        let depth: Int
        var id: String { node.id }
    }

    /// Flattens the tree, descending only into expanded folders (all of them when `expandAll`).
    static func rows(_ nodes: [FileTreeNode], expanded: Set<String>, expandAll: Bool = false,
                     depth: Int = 0) -> [Row] {
        var out: [Row] = []
        for node in nodes {
            out.append(Row(node: node, depth: depth))
            if node.isFolder, expandAll || expanded.contains(node.id) {
                out += rows(node.children, expanded: expanded, expandAll: expandAll, depth: depth + 1)
            }
        }
        return out
    }

    /// Folders opened by default: the top level, so a single-folder torrent shows its contents.
    static func defaultExpanded(_ nodes: [FileTreeNode]) -> Set<String> {
        Set(nodes.filter(\.isFolder).map(\.id))
    }

    /// Mutable scratch tree used only while building.
    private final class Builder {
        var folders: [String: Builder] = [:]
        var folderOrder: [String] = []
        var files: [FileTreeNode] = []
        var path = ""
        var name = ""

        func insert(_ item: FileTreeItem, parts: ArraySlice<String>, prefix: String) {
            guard let head = parts.first else { return }
            if parts.count == 1 {
                files.append(FileTreeNode(id: item.path, name: head, children: [], fileID: item.id,
                                          size: item.size, done: item.done, fileIDs: [item.id]))
                return
            }
            let folderPath = prefix.isEmpty ? head : prefix + "/" + head
            let child: Builder
            if let existing = folders[head] {
                child = existing
            } else {
                child = Builder()
                child.path = folderPath
                child.name = head
                folders[head] = child
                folderOrder.append(head)
            }
            child.insert(item, parts: parts.dropFirst(), prefix: folderPath)
        }

        func nodes() -> [FileTreeNode] {
            let folderNodes: [FileTreeNode] = folderOrder.compactMap { folders[$0]?.node() }
            let byName: (FileTreeNode, FileTreeNode) -> Bool = {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return folderNodes.sorted(by: byName) + files.sorted(by: byName)
        }

        func node() -> FileTreeNode {
            let kids = nodes()
            let size = kids.reduce(Int64(0)) { $0 + $1.size }
            let done = kids.reduce(Int64(0)) { $0 + $1.done }
            // Folder ids get a trailing slash so a file and a folder of the same name never collide.
            return FileTreeNode(id: path + "/", name: name, children: kids, fileID: nil,
                                size: size, done: done, fileIDs: kids.flatMap(\.fileIDs))
        }
    }
}
