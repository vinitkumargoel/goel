import SwiftUI
import GoelCore

/// Shared controls other areas still use: `Dropdown` (AddFlow, Settings) and `ActionMenu` (Detail).
/// Moved unchanged from the old Views folder; the toolbar label and confirm dialog went with the
/// old toolbar (the confirm dialog is now `ConfirmDialogView` in this folder).

struct Dropdown<Value: Hashable>: View {
    enum Item {
        case option(Value, String)
        case separator
    }

    @Binding var selection: Value
    let items: [Item]
    var width: CGFloat? = nil
    var accessibilityName: String = ""
    var onSelect: (Value) -> Void = { _ in }

    @State private var isOpen = false

    @Environment(\.settingRowName) private var rowName

    private var currentLabel: String {
        for case let .option(value, title) in items where value == selection {
            return title
        }
        return ""
    }

    private var spokenName: String {
        if !accessibilityName.isEmpty { return accessibilityName }
        return rowName.isEmpty ? L10n.t("Options") : rowName
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .a11yDecorative()
            }
            .scaledFont(size: Theme.TextSize.body)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .modifier(WidthOrFill(width: width))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yGroup(label: spokenName, value: currentLabel,
                   hint: L10n.t("Activate to choose a different option."))
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .separator:
                        Divider().padding(.vertical, 3)
                    case let .option(value, title):
                        DropdownRow(title: title, isSelected: value == selection) {
                            selection = value
                            isOpen = false
                            onSelect(value)
                        }
                    }
                }
            }
            .padding(5)
            .frame(minWidth: max(160, width ?? 0))
        }
    }
}

private struct WidthOrFill: ViewModifier {
    let width: CGFloat?
    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, alignment: .leading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DropdownRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .scaledFont(size: Theme.TextSize.micro, weight: .bold)
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
                Text(title)
                    .scaledFont(size: Theme.TextSize.body)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.accent.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct ActionMenuItem: Identifiable {
    enum Kind { case action, separator }

    let id = UUID()
    var kind: Kind = .action
    var title: String = ""
    var leadingSymbol: String? = nil
    var trailingSymbol: String? = nil
    var isDestructive: Bool = false
    var action: () -> Void = {}

    static func button(_ title: String,
                       leading: String? = nil,
                       trailing: String? = nil,
                       destructive: Bool = false,
                       _ action: @escaping () -> Void) -> ActionMenuItem {
        ActionMenuItem(kind: .action, title: title, leadingSymbol: leading,
                       trailingSymbol: trailing, isDestructive: destructive, action: action)
    }
}

struct ActionMenu<Label: View>: View {
    let items: [ActionMenuItem]
    var menuWidth: CGFloat = 190
    @ViewBuilder var label: (Bool) -> Label

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            label(isOpen)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "" : L10n.t("Activate to open the menu."))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(items) { item in
                    if item.kind == .separator {
                        Divider().padding(.vertical, 3)
                    } else {
                        ActionMenuRow(item: item) { isOpen = false }
                    }
                }
            }
            .padding(5)
            .frame(minWidth: menuWidth)
        }
    }
}

private struct ActionMenuRow: View {
    let item: ActionMenuItem
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            dismiss()
            item.action()
        } label: {
            HStack(spacing: 8) {
                if let leading = item.leadingSymbol {
                    Image(systemName: leading).scaledFont(size: Theme.TextSize.meta).frame(width: 15)
                }
                Text(item.title).scaledFont(size: Theme.TextSize.body)
                Spacer(minLength: 14)
                if let trailing = item.trailingSymbol {
                    Image(systemName: trailing).scaledFont(size: Theme.TextSize.micro, weight: .semibold)
                }
            }
            .foregroundStyle(item.isDestructive ? Theme.red : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hoverFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.isDestructive
                            ? L10n.t("%@, destructive", item.title) : item.title)
        // A checkmark marks the active choice (Filter menu): say so, not just draw it.
        .accessibilityAddTraits(item.trailingSymbol == "checkmark" ? [.isButton, .isSelected] : .isButton)
    }

    private var hoverFill: Color {
        guard hovering else { return .clear }
        return item.isDestructive ? Theme.red.opacity(0.14) : Theme.accent.opacity(0.14)
    }
}
