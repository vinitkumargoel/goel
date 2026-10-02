import SwiftUI
import GoelCore

// Studio-styled inputs for setting rows. Each one names itself for VoiceOver from the row it sits
// in (`settingRowName`).

/// A small text field (`.field.sm`).
struct SettingsTextField: View {
    @Binding var text: String
    var width: CGFloat? = 180
    var placeholder: String = ""
    var isMonospaced = false
    /// A word placeholder ("Optional") in a mono field stays in the UI font so it can't pass for a
    /// typed value; format examples ("/path/to/script") keep the field's mono.
    var placeholderIsMonospaced: Bool?
    /// Overrides the row title as the spoken name.
    var accessibilityName: String?
    var size: StudioFieldSize = .small
    @Environment(\.settingRowName) private var rowName

    var body: some View {
        StudioFocusedField(size: size) { focus in
            ZStack(alignment: .leading) {
                // Drawn by hand: the field's ink colour would otherwise make the prompt look typed.
                if text.isEmpty {
                    Text(placeholder)
                        .studioFont((placeholderIsMonospaced ?? isMonospaced) ? .monoBody.weight(400) : size.text)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .studioFont(isMonospaced ? .monoBody.weight(400) : size.text)
            }
        }
        .frame(width: width)
        .accessibilityLabel(accessibilityName ?? rowName)
    }
}

/// A small secure field for passwords.
struct SettingsSecureField: View {
    @Binding var text: String
    var width: CGFloat? = 180
    var placeholder: String = ""
    let accessibilityName: String

    var body: some View {
        StudioFocusedField(size: .small) { focus in
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                SecureField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused(focus)
            }
            .studioFont(StudioFieldSize.small.text)
        }
        .frame(width: width)
        .accessibilityLabel(accessibilityName)
    }
}

/// A whole-number field in mono with an optional unit (`.field.sm.mono` + `.unit`).
/// Ungrouped: `.number` would render port 8899 as "8,899", which won't type back.
/// With `range` (from `SettingsBounds`), a value typed outside it is pulled in and says so.
struct SettingsIntField: View {
    @Binding var value: Int
    var unit: String?
    var width: CGFloat? = 90
    var range: ClosedRange<Int>?
    var accessibilityName: String?
    @Environment(\.settingRowName) private var rowName
    @State private var clampNote: String?
    @State private var reformat = 0

    var body: some View {
        SettingsNumberChrome(unit: unit, note: clampNote) { focus in
            TextField("", value: typed, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .focused(focus)
                .id(reformat)
        }
        .frame(width: width)
        .accessibilityLabel(accessibilityName ?? rowName)
    }

    private var typed: Binding<Int> {
        Binding(
            get: { value },
            set: { new in
                guard let range else { value = new; return }
                let result = SettingsBounds.clamp(new, to: range)
                clampNote = result.wasClamped ? SettingsRangeText.clampNote(typed: "\(new)", range: range,
                                                                           using: "\(result.value)") : nil
                value = result.value
                // A clamp to the value already stored changes nothing, so the field would keep the typed text.
                if result.wasClamped { reformat += 1 }
            })
    }
}

/// A decimal field in mono with an optional unit. Ungrouped for the same reason as the int field.
struct SettingsDoubleField: View {
    @Binding var value: Double
    var unit: String?
    var width: CGFloat? = 90
    var range: ClosedRange<Double>?
    var accessibilityName: String?
    @Environment(\.settingRowName) private var rowName
    @State private var clampNote: String?
    @State private var reformat = 0

    var body: some View {
        SettingsNumberChrome(unit: unit, note: clampNote) { focus in
            TextField("", value: typed, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .focused(focus)
                .id(reformat)
        }
        .frame(width: width)
        .accessibilityLabel(accessibilityName ?? rowName)
    }

    private var typed: Binding<Double> {
        Binding(
            get: { value },
            set: { new in
                guard let range, new.isFinite else { value = new; return }
                let result = SettingsBounds.clamp(new, to: range)
                clampNote = result.wasClamped ? SettingsRangeText.clampNote(typed: SettingsRangeText.number(new),
                                                                           range: range,
                                                                           using: SettingsRangeText.number(result.value))
                                              : nil
                value = result.value
                if result.wasClamped { reformat += 1 }
            })
    }
}

private struct SettingsNumberChrome<Field: View>: View {
    var unit: String?
    /// Shown under the field when the typed value was pulled into range.
    var note: String?
    @ViewBuilder var field: (FocusState<Bool>.Binding) -> Field

    var body: some View {
        VStack(alignment: .trailing, spacing: Studio.Space.xxs) {
            StudioFocusedField(size: .small) { focus in
                HStack(spacing: Studio.Space.xs) {
                    field(focus)
                        .studioFont(.monoBody.weight(400))
                    if let unit {
                        Text(unit)
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink3)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                }
            }
            if let note {
                Text(note)
                    .studioFont(.tiny)
                    .foregroundStyle(Studio.Palette.warn)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(note)
            }
        }
    }
}

/// One choice of a ``SettingsSelect``.
struct SettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// A pop-up choice (`.field.sm.sel`): the current value and a chevron; a Studio menu of options.
struct SettingsSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsOption<Value>]
    var width: CGFloat? = 160
    var accessibilityName: String?
    /// Called after a pick, with the new value (like ``Dropdown``'s `onSelect`).
    var onSelect: (Value) -> Void = { _ in }

    @State private var isOpen = false
    @State private var hovered = false
    @State private var highlighted: Int?
    @Environment(\.settingRowName) private var rowName
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    private func pick(_ value: Value) {
        selection = value
        isOpen = false
        onSelect(value)
    }

    private var spokenName: String {
        if let accessibilityName, !accessibilityName.isEmpty { return accessibilityName }
        return rowName.isEmpty ? L10n.t("Options") : rowName
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: Studio.Space.xs) {
                Text(currentTitle)
                    .studioFont(StudioFieldSize.small.text)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: Studio.Space.xxs)
                Image(systemName: "chevron.down")
                    .studioFont(.ui, size: 10, weight: 700)
                    .foregroundStyle(Studio.Palette.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Studio.Space.sm)
            .frame(width: width, height: StudioFieldSize.small.height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .modifier(StudioFieldChrome(isFocused: isOpen || focused, radius: StudioFieldSize.small.radius))
            .overlay {
                if hovered && !isOpen {
                    RoundedRectangle(cornerRadius: StudioFieldSize.small.radius, style: .continuous)
                        .strokeBorder(Studio.Palette.accentLine, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = isEnabled && $0 }
        // VoiceOver meets a pop-up button, as it would on an NSPopUpButton.
        .accessibilityRepresentation {
            Picker(spokenName, selection: Binding(get: { selection }, set: pick)) {
                ForEach(options) { option in
                    Text(option.title).tag(option.value)
                }
            }
        }
        .accessibilityHint(L10n.t("Activate to choose a different option."))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    StudioMenuRow(title: option.title, isChecked: option.value == selection,
                                  isHighlighted: highlighted == index) {
                        pick(option.value)
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
}

/// A vertical radio list (`.radio`), for a few mutually exclusive choices that each deserve a line.
struct SettingsRadioGroup<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsOption<Value>]
    var accessibilityName: String?
    @Environment(\.settingRowName) private var rowName

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            ForEach(options) { option in
                SettingsRadioButton(title: option.title, isOn: option.value == selection) {
                    selection = option.value
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName ?? rowName)
    }
}

private struct SettingsRadioButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Studio.Space.s) {
                ZStack {
                    Circle().fill(Studio.Palette.card)
                    if isOn {
                        Circle().strokeBorder(Studio.Palette.accent, lineWidth: 5)
                    } else {
                        Circle().strokeBorder(hovered ? Studio.Palette.accentLine : Studio.Palette.hairlineStrong,
                                              lineWidth: 1.5)
                    }
                }
                .frame(width: 17, height: 17)
                .studioButtonFocusRing(shape: Circle())
                Text(title)
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.studioPlain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = isEnabled && $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A small trailing icon button for list rows (remove a feed, a login, a rule).
struct SettingsRowIconButton: View {
    let symbol: String
    let label: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(StudioIconButtonStyle(size: .small))
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}
