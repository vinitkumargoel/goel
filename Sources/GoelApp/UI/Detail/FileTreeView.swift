import SwiftUI
import GoelCore

/// A torrent's files as a folder tree: tri-state checks (Included / Skipped / Partly), per-folder
/// totals, a filter field and a Select menu. The caller owns the wanted set and applies changes;
/// `trailing` draws a file's own control (the priority menu).
/// The file trees' shared indentation (the detail panel's Files tab and the Add sheet's list).
enum FileTreeMetrics {
    /// Each folder level shifts its rows right by this much.
    static let indentPerLevel: CGFloat = 18

    static func indent(depth: Int) -> CGFloat {
        CGFloat(depth) * indentPerLevel + Studio.Space.xs
    }
}

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
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            toolbar
            summary
            if rows.isEmpty {
                DetailEmptyLine(text: L10n.t("No files match “%@”", query))
            }
            LazyVStack(alignment: .leading, spacing: Studio.Space.hair) {
                ForEach(rows) { row in
                    rowView(row, isOpen: open.contains(row.id) || !query.isEmpty)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Studio.Space.s) {
            StudioSearchField(text: $query, placeholder: L10n.t("Filter files"), size: .small)
                .accessibilityLabel(L10n.t("Filter files"))
            DetailMenuButton(title: L10n.t("Select"), accessibilityLabel: L10n.t("Select files")) {
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
        }
    }

    private var summary: some View {
        let chosen = items.filter { wanted.contains($0.id) }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.size }
        return Text(L10n.t("%1$d of %2$d files · %3$@", chosen.count, items.count, bytes.byteString))
            .studioFont(.caption)
            .monospacedDigit()
            .foregroundStyle(Studio.Palette.ink3)
    }

    private func rowView(_ row: FileTree.Row, isOpen: Bool) -> some View {
        let node = row.node
        let state = FileTree.state(of: node, wanted: wanted)
        return HStack(spacing: Studio.Space.s) {
            disclosure(node, isOpen: isOpen)
            checkbox(node, state: state)
            FileTreeRowLabel(node: node, state: state, showsProgress: showsProgress)
            if let fileID = node.fileID, let item = items.first(where: { $0.id == fileID }) {
                trailing(item)
            }
        }
        .padding(.leading, FileTreeMetrics.indent(depth: row.depth))
        .padding(.trailing, Studio.Space.xs)
        .padding(.vertical, Studio.Space.xs)
        .background {
            if node.isFolder && row.depth == 0 {
                RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous).fill(Studio.Palette.well)
            }
        }
    }

    @ViewBuilder
    private func disclosure(_ node: FileTreeNode, isOpen: Bool) -> some View {
        if node.isFolder {
            Button { toggleExpanded(node) } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(StudioFonts.font(.ui, size: 9.5, weight: 700))
                    .foregroundStyle(Studio.Palette.ink3)
                    .frame(width: 12, height: 17)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton(isOpen ? L10n.t("Collapse %@", node.name) : L10n.t("Expand %@", node.name))
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private func checkbox(_ node: FileTreeNode, state: FileCheckState) -> some View {
        Button { onChange(FileTree.toggling(node, in: wanted)) } label: {
            DetailCheckMark(state: state)
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

/// The Studio check (`.check`): accent fill with a tick, a bar when partly included.
struct DetailCheckMark: View {
    let state: FileCheckState
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            if state == .off {
                shape.fill(Studio.Palette.card)
                shape.strokeBorder(hovered ? Studio.Palette.accent : Studio.Palette.hairlineStrong, lineWidth: 1.5)
            } else {
                shape.fill(Studio.Palette.accent)
                Image(systemName: state == .mixed ? "minus" : "checkmark")
                    .font(StudioFonts.font(.ui, size: 10, weight: 800))
                    .foregroundStyle(Studio.Palette.onAccent)
            }
        }
        .frame(width: 17, height: 17)
        .contentShape(shape)
        .onHover { hovered = $0 }
    }
}

/// Artwork, name, a thin progress bar, and the size with how much is done. A skipped row is
/// faint and struck through; a folder's size is the sum of its files.
private struct FileTreeRowLabel: View {
    let node: FileTreeNode
    let state: FileCheckState
    let showsProgress: Bool

    private var kind: StudioArtKind {
        node.isFolder ? .folder : StudioArtKind(FileType.classify(fileName: node.name, isTorrent: false))
    }

    var body: some View {
        let skipped = state == .off
        HStack(spacing: Studio.Space.s) {
            StudioFileArtwork(kind: kind, size: .xs, isGhost: skipped)
            VStack(alignment: .leading, spacing: 3) {
                FileNameText(node.name, lineLimit: 1)
                    .studioFont(node.isFolder ? .bodyStrong : .body)
                    .foregroundStyle(skipped ? Studio.Palette.ink3 : Studio.Palette.ink)
                    .strikethrough(skipped && !node.isFolder, color: Studio.Palette.ink3)
                HStack(spacing: Studio.Space.s) {
                    // The bar takes what is left; size and percent sit in fixed trailing columns
                    // so they line up from row to row.
                    if showsProgress && !skipped {
                        StudioLinearProgress(fraction: node.fraction, tone: node.fraction >= 1 ? .good : .accent,
                                             height: 3)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text(node.size.byteString)
                        .studioFont(.monoSmall)
                        .foregroundStyle(skipped ? Studio.Palette.ink3 : Studio.Palette.ink2)
                        .frame(minWidth: 58, alignment: .trailing)
                        .accessibilityLabel(A11y.bytes(node.size))
                    if showsProgress {
                        Text(skipped ? L10n.t("Skipped") : DetailNetworkText.percent(node.fraction))
                            .studioFont(skipped ? .caption : .monoSmall)
                            .foregroundStyle(!skipped && node.fraction >= 1 ? Studio.Palette.good : Studio.Palette.ink3)
                            .frame(minWidth: 40, alignment: .trailing)
                            .accessibilityLabel(skipped ? L10n.t("Skipped") : A11y.percent(node.fraction))
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
