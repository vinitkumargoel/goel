import SwiftUI

// Our own dropdown, action-menu, and confirmation-dialog controls — drawn and
// styled in-app instead of leaning on the system `Picker` menu, `Menu`, and
// `.confirmationDialog`. They share one visual language (hairline borders, the
// accent-tinted hover row, the same corner radii) so every popout in the app
// looks like it belongs to GoelDownloader rather than to AppKit.

// MARK: - Dropdown (selection)

/// A custom replacement for a menu-style `Picker`: a bordered trigger showing the
/// current label + chevron, opening a popover list with a checkmark on the active
/// row and an accent hover highlight.
struct Dropdown<Value: Hashable>: View {
    /// One entry in the list — a selectable option or a thin separator.
    enum Item {
        case option(Value, String)
        case separator
    }

    @Binding var selection: Value
    let items: [Item]
    /// Fixed trigger width; `nil` lets the trigger fill its container.
    var width: CGFloat? = nil
    /// Invoked after `selection` is updated when the user picks a row, so call
    /// sites can react (e.g. the "Choose folder…" sentinel) without a separate
    /// `.onChange`.
    var onSelect: (Value) -> Void = { _ in }

    @State private var isOpen = false

    private var currentLabel: String {
        for case let .option(value, title) in items where value == selection {
            return title
        }
        return ""
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .modifier(WidthOrFill(width: width))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// Applies a fixed width when given, otherwise lets the view fill the available
/// width — keeps the leading text aligned in both modes.
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
                Text(title)
                    .font(.system(size: 12.5))
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
    }
}

// MARK: - Action menu

/// One row in an ``ActionMenu``: a tappable command or a separator.
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

    static var separator: ActionMenuItem { ActionMenuItem(kind: .separator) }
}

/// A custom replacement for `Menu`: a caller-styled trigger that opens a popover
/// of `ActionMenuItem`s. The label closure receives whether the menu is open so
/// the trigger can show an active state.
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
                    Image(systemName: leading).font(.system(size: 11)).frame(width: 15)
                }
                Text(item.title).font(.system(size: 12.5))
                Spacer(minLength: 14)
                if let trailing = item.trailingSymbol {
                    Image(systemName: trailing).font(.system(size: 10, weight: .semibold))
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
    }

    private var hoverFill: Color {
        guard hovering else { return .clear }
        return item.isDestructive ? Theme.red.opacity(0.14) : Theme.accent.opacity(0.14)
    }
}

/// The pill trigger used by the toolbar's menus (Select / Sort / Filter): an
/// icon, a title, and a dropdown chevron, with a subtle active/hover fill.
struct ToolbarMenuLabel: View {
    let title: String
    let systemImage: String
    let active: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 12))
            Text(title).font(.system(size: 13))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background((active || hovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05)),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Confirmation dialog

/// A window-level modal confirm sheet — our own replacement for
/// `.confirmationDialog`. Driven by ``AppViewModel/confirmRequest`` and rendered
/// once at the root so any call site can raise it via ``AppViewModel/requestConfirm``.
struct ConfirmDialogView: View {
    let request: AppViewModel.ConfirmRequest
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(spacing: 14) {
                Image(systemName: request.isDestructive ? "trash.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(request.isDestructive ? Theme.red : Theme.accent)

                VStack(spacing: 7) {
                    Text(request.title)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text(request.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    DialogButton(title: "Cancel", kind: .normal, action: dismiss)
                        .keyboardShortcut(.cancelAction)
                    DialogButton(title: request.confirmTitle,
                                 kind: request.isDestructive ? .destructive : .primary) {
                        request.onConfirm()
                        dismiss()
                    }
                }
                .padding(.top, 2)
            }
            .padding(22)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
            .shadow(radius: 30, y: 12)
        }
    }
}

private struct DialogButton: View {
    enum Kind { case normal, primary, destructive }
    let title: String
    let kind: Kind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: kind == .normal ? .regular : .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(kind == .normal ? Theme.hairline : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        kind == .normal ? .primary : .white
    }

    private var background: Color {
        switch kind {
        case .normal: return Color.primary.opacity(hovering ? 0.10 : 0.05)
        case .primary: return hovering ? Theme.accentPress : Theme.accent
        case .destructive: return Theme.red.opacity(hovering ? 0.85 : 1)
        }
    }
}
