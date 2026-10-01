import SwiftUI
import GoelCore

/// A torrent's files as a folder tree: tri-state checkboxes, per-folder totals, a filter field,
/// and a "Select ▸" menu. Reusable: the Files tab passes live progress; an Add sheet can pass
/// zero `done` bytes and hide progress. The caller owns the wanted set and applies changes.
struct FileTreeView<Trailing: View>: View {
    let items: [FileTreeItem]
    let wanted: Set<Int>
    var showsProgress = true
    let onChange: (Set<Int>) -> Void
    @ViewBuilder var trailing: (FileTreeItem) -> Trailing

    @State private var query = ""
    @State private var expanded: Set<String>?

    private var tree: [FileTreeNode] { FileTree.build(items) }

    var body: some View {
        let nodes = FileTree.filtered(tree, query: query)
        let open = expanded ?? FileTree.defaultExpanded(nodes)
        let rows = FileTree.rows(nodes, expanded: open, expandAll: !query.isEmpty)
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            summary
            Divider()
            if rows.isEmpty {
                Text(L10n.t("No files match “%@”", query))
                    .scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row, isOpen: open.contains(row.id) || !query.isEmpty)
                    Divider()
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField(L10n.t("Filter files"), text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("Filter files"))
            selectMenu
        }
    }

    private var summary: some View {
        let chosen = items.filter { wanted.contains($0.id) }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.size }
        return Text(L10n.t("%1$d of %2$d files · %3$@", chosen.count, items.count, bytes.byteString))
            .scaledFont(size: Theme.TextSize.caption, monospacedDigit: true)
            .foregroundStyle(.secondary)
    }

    private var selectMenu: some View {
        Menu(L10n.t("Select")) {
            Button(L10n.t("All")) { onChange(FileTree.applying(.all, to: items)) }
            Button(L10n.t("None")) { onChange(FileTree.applying(.none, to: items)) }
            Button(L10n.t("Only Video")) { onChange(FileTree.applying(.onlyVideo, to: items)) }
            Menu(L10n.t("By Extension")) {
                ForEach(FileTree.extensionCounts(items), id: \.ext) { entry in
                    Button(".\(entry.ext) (\(entry.count))") {
                        onChange(FileTree.applying(.byExtension(entry.ext), to: items))
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.t("Select files"))
    }

    private func rowView(_ row: FileTree.Row, isOpen: Bool) -> some View {
        let node = row.node
        let state = FileTree.state(of: node, wanted: wanted)
        return HStack(spacing: 6) {
            disclosure(node, isOpen: isOpen)
            checkbox(node, state: state)
            FileTreeRowLabel(node: node, showsProgress: showsProgress)
            if let fileID = node.fileID, let item = items.first(where: { $0.id == fileID }) {
                trailing(item)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func disclosure(_ node: FileTreeNode, isOpen: Bool) -> some View {
        if node.isFolder {
            Button { toggleExpanded(node) } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .a11yButton(isOpen ? L10n.t("Collapse %@", node.name) : L10n.t("Expand %@", node.name))
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private func checkbox(_ node: FileTreeNode, state: FileCheckState) -> some View {
        Button { onChange(FileTree.toggling(node, in: wanted)) } label: {
            Image(systemName: Self.symbol(for: state))
                .foregroundStyle(state == .off ? Color.secondary : Theme.accent)
        }
        .buttonStyle(.plain)
        .a11yButton(state == .on ? L10n.t("Skip %@", node.name) : L10n.t("Download %@", node.name))
        .accessibilityValue(Self.spoken(state))
    }

    private func toggleExpanded(_ node: FileTreeNode) {
        var open = expanded ?? FileTree.defaultExpanded(tree)
        if open.contains(node.id) { open.remove(node.id) } else { open.insert(node.id) }
        expanded = open
    }

    static func symbol(for state: FileCheckState) -> String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        }
    }

    static func spoken(_ state: FileCheckState) -> String {
        switch state {
        case .on: return L10n.t("Included")
        case .off: return L10n.t("Skipped")
        case .mixed: return L10n.t("Partly included")
        }
    }
}

extension FileTreeView where Trailing == EmptyView {
    init(items: [FileTreeItem], wanted: Set<Int>, showsProgress: Bool = true,
         onChange: @escaping (Set<Int>) -> Void) {
        self.init(items: items, wanted: wanted, showsProgress: showsProgress, onChange: onChange) { _ in
            EmptyView()
        }
    }
}

/// Name, optional progress bar, and size (a folder's is the sum of its files).
private struct FileTreeRowLabel: View {
    let node: FileTreeNode
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "doc")
                .foregroundStyle(.secondary).frame(width: 14)
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .scaledFont(size: Theme.TextSize.body, weight: node.isFolder ? .medium : .regular)
                    .lineLimit(1).truncationMode(.middle)
                if showsProgress {
                    ProgressView(value: node.fraction).tint(Theme.green).controlSize(.small)
                }
            }
            Spacer(minLength: 4)
            Text(node.size.byteString)
                .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .accessibilityLabel(A11y.bytes(node.size))
        }
        .accessibilityElement(children: .combine)
    }
}
