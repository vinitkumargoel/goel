import SwiftUI
import GoelCore

/// One item of a Downloads menu, as data. The same nodes draw the native context menus
/// (``DownloadMenuContent``) and the Studio popover menus (``DownloadStudioMenu``) — so the
/// header's Sort / Group / Select / Type popovers, and the snapshot rendition of a context menu,
/// list exactly what the real menu lists.
struct DownloadMenuNode {
    enum Kind {
        case button(role: ButtonRole?, isEnabled: Bool, action: () -> Void)
        /// A checkable item. Exclusive choices (a limit, a density) are toggles whose `set(true)`
        /// picks them, so the menu shows a real checkmark and VoiceOver reads the state.
        case toggle(isOn: Bool, set: (Bool) -> Void)
        case submenu([DownloadMenuNode])
        case section([DownloadMenuNode])
        case divider
        /// Convert To / Extract Audio: drawn by ``MediaMenuItems``, which observes the job centre.
        case media(DownloadTask, AppViewModel)
    }

    var title: String
    var symbol: String?
    /// Popover menus show it at the trailing edge (a count, a shortcut, a sort direction).
    var trailing: String?
    var kind: Kind

    static func button(_ title: String, symbol: String? = nil, trailing: String? = nil,
                       role: ButtonRole? = nil, isEnabled: Bool = true,
                       action: @escaping () -> Void) -> DownloadMenuNode {
        DownloadMenuNode(title: title, symbol: symbol, trailing: trailing,
                         kind: .button(role: role, isEnabled: isEnabled, action: action))
    }

    static func toggle(_ title: String, symbol: String? = nil, trailing: String? = nil, isOn: Bool,
                       set: @escaping (Bool) -> Void) -> DownloadMenuNode {
        DownloadMenuNode(title: title, symbol: symbol, trailing: trailing, kind: .toggle(isOn: isOn, set: set))
    }

    /// An exclusive choice: picking it again leaves it picked.
    static func choice(_ title: String, trailing: String? = nil, isOn: Bool,
                       pick: @escaping () -> Void) -> DownloadMenuNode {
        toggle(title, trailing: trailing, isOn: isOn) { on in if on { pick() } }
    }

    static func submenu(_ title: String, symbol: String? = nil, _ children: [DownloadMenuNode]) -> DownloadMenuNode {
        DownloadMenuNode(title: title, symbol: symbol, kind: .submenu(children))
    }

    static func section(_ title: String, _ children: [DownloadMenuNode]) -> DownloadMenuNode {
        DownloadMenuNode(title: title, kind: .section(children))
    }

    static let divider = DownloadMenuNode(title: "", kind: .divider)

    var isDestructive: Bool {
        if case .button(let role, _, _) = kind { return role == .destructive }
        return false
    }
}

// MARK: - Native menus

/// Draws nodes as native menu items, for `.contextMenu` and `Menu`.
struct DownloadMenuContent: View {
    let nodes: [DownloadMenuNode]

    var body: some View {
        ForEach(nodes.indices, id: \.self) { index in
            DownloadMenuItem(node: nodes[index])
        }
    }
}

private struct DownloadMenuItem: View {
    let node: DownloadMenuNode

    var body: some View {
        switch node.kind {
        case .button(let role, let isEnabled, let action):
            Button(role: role, action: action) { label }
                .disabled(!isEnabled)
        case .toggle(let isOn, let set):
            Toggle(isOn: Binding(get: { isOn }, set: set)) { Text(node.title) }
        case .submenu(let children):
            Menu {
                AnyView(DownloadMenuContent(nodes: children))
            } label: { label }
        case .section(let children):
            Section(node.title) {
                AnyView(DownloadMenuContent(nodes: children))
            }
        case .divider:
            Divider()
        case .media(let task, let vm):
            MediaMenuItems(task: task, vm: vm, center: vm.mediaJobs)
        }
    }

    @ViewBuilder
    private var label: some View {
        if let symbol = node.symbol {
            Label(node.title, systemImage: symbol)
        } else {
            Text(node.title)
        }
    }
}

// MARK: - Studio menus

/// Draws nodes in the Studio menu look (`.menu` / `.mi`): the header's popover menus, and the
/// still rendition of a context menu in snapshots. `onPick` runs after an item's action, to
/// close the popover.
struct DownloadStudioMenu: View {
    let nodes: [DownloadMenuNode]
    /// The narrowest the menu draws; it grows to fit its longest item.
    var width: CGFloat? = 240
    var onPick: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DownloadStudioMenuRows(nodes: nodes, onPick: onPick)
        }
        .padding(Studio.Space.xs)
        // A minimum, not a cap: a long item ("Remove 3 and Move Files to Trash") widens the menu
        // instead of truncating.
        .frame(minWidth: width, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DownloadStudioMenuRows: View {
    let nodes: [DownloadMenuNode]
    let onPick: () -> Void

    var body: some View {
        ForEach(nodes.indices, id: \.self) { index in
            row(nodes[index], isFirst: index == 0)
        }
    }

    @ViewBuilder
    private func row(_ node: DownloadMenuNode, isFirst: Bool) -> some View {
        switch node.kind {
        case .button(_, let isEnabled, let action):
            DownloadStudioMenuRow(node: node, isChecked: false, showsCheckColumn: false) {
                action()
                onPick()
            }
            .disabled(!isEnabled)
        case .toggle(let isOn, let set):
            DownloadStudioMenuRow(node: node, isChecked: isOn, showsCheckColumn: true) {
                set(!isOn)
                onPick()
            }
        case .submenu:
            DownloadStudioMenuRow(node: node, isChecked: false, showsCheckColumn: false,
                                  trailingOverride: "›") {}
        case .section(let children):
            Text(node.title)
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.ink3)
                .padding(.horizontal, Studio.Space.sm)
                .padding(.top, isFirst ? 5 : 7)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
            AnyView(DownloadStudioMenuRows(nodes: children, onPick: onPick))
        case .divider:
            // Strong: menus sit on `cardRaised`, where the plain hairline vanishes in dark.
            StudioDivider(strong: true)
                .padding(.vertical, 5)
                .padding(.horizontal, Studio.Space.xs)
        case .media(let task, let vm):
            AnyView(DownloadStudioMenuRows(nodes: MediaMenuNodes.make(task: task, vm: vm, center: vm.mediaJobs),
                                           onPick: onPick))
        }
    }
}

/// One `.mi` row: optional check column or glyph, title, trailing text; accent on hover.
private struct DownloadStudioMenuRow: View {
    let node: DownloadMenuNode
    let isChecked: Bool
    let showsCheckColumn: Bool
    var trailingOverride: String?
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let tint = node.isDestructive ? Studio.Palette.bad : Studio.Palette.ink
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
        Button(action: action) {
            HStack(spacing: Studio.Space.sm) {
                if showsCheckColumn {
                    Image(systemName: "checkmark")
                        .font(StudioFonts.font(.ui, size: 11.5, weight: 700))
                        .foregroundStyle(hovered ? Studio.Palette.onAccent : Studio.Palette.accent)
                        .opacity(isChecked ? 1 : 0)
                        .frame(width: 15)
                } else if let symbol = node.symbol {
                    Image(systemName: symbol)
                        .font(StudioFonts.font(.ui, size: 12.5, weight: 600))
                        .foregroundStyle(hovered ? Studio.Palette.onAccent
                                         : node.isDestructive ? Studio.Palette.bad : Studio.Palette.ink3)
                        .frame(width: 15)
                }
                Text(node.title)
                    .studioFont(.body)
                    .lineLimit(1)
                Spacer(minLength: Studio.Space.l)
                if let trailing = trailingOverride ?? node.trailing {
                    Text(trailing)
                        .studioFont(.monoSmall)
                        .foregroundStyle(hovered ? Studio.Palette.onAccent : Studio.Palette.ink3)
                }
            }
            .foregroundStyle(hovered ? Studio.Palette.onAccent : tint)
            .padding(.horizontal, Studio.Space.sm)
            .frame(minHeight: 28)
            .background(hovered ? Studio.Palette.accent : .clear, in: shape)
            .studioButtonFocusRing(shape: shape)
            .contentShape(shape)
        }
        .buttonStyle(.studioPlain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = isEnabled && $0 }
        .accessibilityLabel(node.title)
        .accessibilityValue(node.trailing ?? "")
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}
