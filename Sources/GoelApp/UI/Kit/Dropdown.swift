import SwiftUI
import GoelCore

/// A pop-up choice in Studio field chrome: the current value and a chevron on the field fill,
/// a Studio menu of options (with separators) in a popover.
///
///     Dropdown(selection: $start, items: [.option("now", "Now"), .separator, .option("later", "Later")],
///              accessibilityName: "Start") { picked in … }
///
/// Settings panes use ``SettingsSelect``, which draws the same field. The open menu follows
/// ``MenuKeyboard``; VoiceOver meets it as a pop-up button (a `Picker` stands in for it).
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
    @State private var highlighted: Int?
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

    /// The pickable options, in order: what the keyboard steps through.
    private var options: [(value: Value, title: String)] {
        items.compactMap { if case let .option(value, title) = $0 { return (value, title) } else { return nil } }
    }

    private func pick(_ value: Value) {
        selection = value
        isOpen = false
        onSelect(value)
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
        .accessibilityRepresentation {
            Picker(spokenName, selection: Binding(get: { selection }, set: pick)) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.title).tag(option.value)
                }
            }
        }
        .accessibilityHint(L10n.t("Activate to choose a different option."))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { menu }
    }

    private var menu: some View {
        let options = self.options
        // Each item's place among the options, or nil for a separator.
        var next = 0
        let ordinals: [Int?] = items.map { item in
            guard case .option = item else { return nil }
            defer { next += 1 }
            return next
        }
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                switch item {
                case .separator:
                    StudioDivider(strong: true)
                        .padding(.vertical, Studio.Space.xxs)
                case let .option(value, title):
                    StudioMenuRow(title: title, isChecked: value == selection,
                                  isHighlighted: highlighted != nil && highlighted == ordinals[index]) {
                        pick(value)
                    }
                }
            }
        }
        .padding(Studio.Space.xs)
        .frame(minWidth: max(170, width ?? 0), alignment: .leading)
        .background(Studio.Palette.cardRaised)
        .studioMenuKeyboard(titles: options.map(\.title),
                            initial: options.firstIndex { $0.value == selection },
                            highlighted: $highlighted,
                            onActivate: { pick(options[$0].value) },
                            onClose: { isOpen = false })
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
