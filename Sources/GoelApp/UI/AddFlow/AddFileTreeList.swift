import SwiftUI
import GoelCore

/// The confirm step's files as a tree (folders from the paths, via `FileTree`). For a torrent each
/// file and folder can be ticked off; a folder shows a bar when only some of its files are kept.
struct AddFileTreeList: View {
    let files: [TransferFile]
    let selectable: Bool
    @Binding var deselectedFileIDs: Set<Int>

    @State private var expanded: Set<String>?

    private var items: [FileTreeItem] { files.map(FileTreeItem.init) }
    private var allIDs: Set<Int> { Set(files.map(\.id)) }
    private var wanted: Set<Int> { allIDs.subtracting(deselectedFileIDs) }

    var body: some View {
        let nodes = FileTree.build(items)
        let open = expanded ?? FileTree.defaultExpanded(nodes)
        let rows = FileTree.rows(nodes, expanded: open)
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            HStack {
                AddFieldLabel(L10n.t("Files"))
                Spacer()
                if selectable {
                    let kept = files.filter { wanted.contains($0.id) }
                    Text(L10n.t("%1$d of %2$d · %3$@", kept.count, files.count,
                                kept.reduce(Int64(0)) { $0 + $1.length }.byteString))
                        .studioFont(.mono)
                        .foregroundStyle(Studio.Palette.ink3)
                }
            }
            AddListWell(height: min(CGFloat(rows.count) * 30 + 10, 190)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, open: open)
                    }
                }
            }
        }
    }

    private func rowView(_ row: FileTree.Row, open: Set<String>) -> some View {
        let node = row.node
        let state = FileTree.state(of: node, wanted: wanted)
        let isOpen = open.contains(node.id)
        return HStack(spacing: Studio.Space.s) {
            if node.isFolder {
                Button {
                    toggleExpanded(node.id, current: open)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(StudioFonts.font(.ui, size: 10, weight: 700))
                        .foregroundStyle(Studio.Palette.ink3)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? L10n.t("Collapse %@", node.name) : L10n.t("Expand %@", node.name))
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            if selectable {
                Button {
                    deselectedFileIDs = allIDs.subtracting(FileTree.toggling(node, in: wanted))
                } label: {
                    AddCheckGlyph(state: state)
                }
                .buttonStyle(.plain)
                .a11yButton(state == .off ? L10n.t("Download %@", node.name) : L10n.t("Skip %@", node.name))
                .accessibilityValue(state == .off ? L10n.t("Skipped")
                                    : state == .mixed ? L10n.t("Partly included") : L10n.t("Included"))
            }
            StudioFileArtwork(kind: node.isFolder ? .folder
                                  : StudioArtKind(FileType.classify(fileName: node.name, isTorrent: false)),
                              size: .xs, isFaded: selectable && state == .off)
            FileNameText(node.name, lineLimit: 1)
                .studioFont(node.isFolder ? .small.weight(600) : .small)
                .foregroundStyle(state == .off && selectable ? Studio.Palette.ink3 : Studio.Palette.ink)
            Spacer(minLength: Studio.Space.s)
            Text(node.size.byteString)
                .studioFont(.mono)
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityLabel(A11y.bytes(node.size))
        }
        .padding(.leading, CGFloat(row.depth) * 18 + Studio.Space.xs)
        .padding(.trailing, Studio.Space.s)
        .frame(height: 30)
    }

    private func toggleExpanded(_ id: String, current: Set<String>) {
        var current = current
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        expanded = current
    }
}
