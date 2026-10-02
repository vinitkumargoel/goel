import SwiftUI
import GoelCore

/// A pop-up choice in Studio field chrome: the current value and a chevron on the field fill,
/// a Studio menu of options (with separators) in a popover.
///
///     Dropdown(selection: $start, items: [.option("now", "Now"), .separator, .option("later", "Later")],
///              accessibilityName: "Start") { picked in … }
///
/// Settings panes use ``SettingsSelect``, which draws the same field.
struct Dropdown<Value: Hashable>: View {
    enum Item {
        case option(Value, String)
        case separator
    }

    @Binding var selection: Value
    let items: [Item]
    /// `nil` fills the available width.
    var width: CGFloat? = nil
    var accessibilityName: String = ""
    var size: StudioFieldSize = .small
    var onSelect: (Value) -> Void = { _ in }

    @State private var isOpen = false
    @State private var hovered = false
    @FocusState private var focused: Bool

    @Environment(\.settingRowName) private var rowName
    @Environment(\.isEnabled) private var isEnabled

    init(selection: Binding<Value>, items: [Item], width: CGFloat? = nil, accessibilityName: String = "",
         size: StudioFieldSize = .small, onSelect: @escaping (Value) -> Void = { _ in }) {
        _selection = selection
        self.items = items
        self.width = width
        self.accessibilityName = accessibilityName
        self.size = size
        self.onSelect = onSelect
    }

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
        Button { isOpen.toggle() } label: {
            HStack(spacing: Studio.Space.xs) {
                Text(currentLabel)
                    .studioFont(size.text)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Studio.Space.xxs)
                Image(systemName: "chevron.down")
                    .studioFont(.ui, size: 10, weight: 700)
                    .foregroundStyle(Studio.Palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Studio.Space.sm)
            .frame(height: size.height)
            .modifier(WidthOrFill(width: width))
            .modifier(StudioFieldChrome(isFocused: isOpen || focused, radius: size.radius))
            .overlay {
                if hovered && !isOpen {
                    RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                        .strokeBorder(Studio.Palette.accentLine, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = isEnabled && $0 }
        .help(currentLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenName)
        .accessibilityValue(currentLabel)
        .accessibilityHint(L10n.t("Activate to choose a different option."))
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .separator:
                        StudioDivider(strong: true)
                            .padding(.vertical, Studio.Space.xxs)
                    case let .option(value, title):
                        StudioMenuRow(title: title, isChecked: value == selection) {
                            selection = value
                            isOpen = false
                            onSelect(value)
                        }
                    }
                }
            }
            .padding(Studio.Space.xs)
            .frame(minWidth: max(170, width ?? 0), alignment: .leading)
            .background(Studio.Palette.cardRaised)
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
