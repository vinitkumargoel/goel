import SwiftUI
import GoelCore

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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .a11yDecorative()
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.isDestructive
                            ? L10n.t("%@, destructive", item.title) : item.title)
        .accessibilityAddTraits(.isButton)
    }

    private var hoverFill: Color {
        guard hovering else { return .clear }
        return item.isDestructive ? Theme.red.opacity(0.14) : Theme.accent.opacity(0.14)
    }
}

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
        .a11yGroup(label: title,
                   hint: L10n.t("Activate to open the %@ menu.", L10n.midSentence(title)))
        .accessibilityAddTraits(.isButton)
    }
}

struct ConfirmDialogView: View {
    let request: AppViewModel.ConfirmRequest
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .a11yDecorative()

            VStack(spacing: 14) {
                Image(systemName: request.isDestructive ? "trash.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(request.isDestructive ? Theme.red : Theme.accent)
                    .a11yDecorative()

                VStack(spacing: 7) {
                    Text(request.title)
                        .scaledFont(size: 14, weight: .semibold)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(request.message)
                        .scaledFont(size: 12)
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
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .padding(22)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
            .shadow(radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel(request.title)
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
                .scaledFont(size: 13, weight: kind == .normal ? .regular : .semibold)
                .foregroundStyle(foreground)
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(kind == .normal ? Theme.hairline : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(kind == .destructive ? "\(title), destructive" : title)
        .accessibilityAddTraits(.isButton)
    }

    /// Derived from the fill, not hard-coded white: accent and red are light in three of the four themes, where white measured 2.0–2.8:1.
    private var foreground: Color {
        switch kind {
        case .normal: return .primary
        case .primary: return Theme.onAccent
        case .destructive: return Theme.onRed
        }
    }

    private var background: Color {
        switch kind {
        case .normal: return Color.primary.opacity(hovering ? 0.10 : 0.05)
        case .primary: return hovering ? Theme.accentPress : Theme.accent
        case .destructive: return Theme.red.opacity(hovering ? 0.85 : 1)
        }
    }
}
