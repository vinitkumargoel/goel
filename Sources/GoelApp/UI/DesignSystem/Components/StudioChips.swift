import SwiftUI
import GoelCore

/// A static rounded chip (`.chip`): a label with an optional glyph or colour swatch.
///
///     StudioChip("Medium", symbol: "gauge.with.dots.needle.33percent", size: .small)
struct StudioChip: View {
    enum Size: Sendable { case small, regular }

    let title: String
    var symbol: String?
    var swatch: Color?
    var size: Size = .regular

    init(_ title: String, symbol: String? = nil, swatch: Color? = nil, size: Size = .regular) {
        self.title = title
        self.symbol = symbol
        self.swatch = swatch
        self.size = size
    }

    var body: some View {
        HStack(spacing: 6) {
            if let swatch {
                Circle().fill(swatch).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            if let symbol {
                Image(systemName: symbol)
                    .studioFont(.ui, size: size == .small ? 11 : 12, weight: 650)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .modifier(StudioChipChrome(isOn: false, size: size, hovered: false))
    }
}

/// A filter chip with a count (`.chip .n`), selected when `isOn`. A button: it toggles a filter.
///
///     StudioFilterChip("Active", count: 4, isOn: filter == .active) { filter = .active }
struct StudioFilterChip: View {
    let title: String
    var count: Int?
    var symbol: String?
    var isOn: Bool
    var size: StudioChip.Size = .regular
    let action: () -> Void

    init(_ title: String, count: Int? = nil, symbol: String? = nil, isOn: Bool,
         size: StudioChip.Size = .regular, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.symbol = symbol
        self.isOn = isOn
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .studioFont(.ui, size: size == .small ? 11 : 12, weight: 650)
                }
                Text(title)
                if let count {
                    Text(verbatim: "\(count)")
                        .studioFont(.monoSmall)
                        .foregroundStyle(isOn ? Studio.Palette.inverseInk.opacity(0.7) : Studio.Palette.ink3)
                }
            }
        }
        .buttonStyle(StudioPillButtonStyle(isOn: isOn, size: size))
        .accessibilityLabel(title)
        .accessibilityValue(count.map { L10n.t("%d items", $0) } ?? "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Shared chip chrome: card fill and hairline, or solid ink when selected.
struct StudioChipChrome: ViewModifier {
    let isOn: Bool
    let size: StudioChip.Size
    let hovered: Bool

    func body(content: Content) -> some View {
        content
            .studioFont(.callout.size(size == .small ? 11.5 : 12.5).weight(600))
            .lineLimit(1)
            .foregroundStyle(isOn ? Studio.Palette.inverseInk : hovered ? Studio.Palette.ink : Studio.Palette.ink2)
            .padding(.horizontal, size == .small ? 9 : 12)
            .frame(minHeight: size == .small ? 24 : 30)
            .background(Capsule().fill(isOn ? Studio.Palette.ink : hovered ? Studio.Palette.well : Studio.Palette.card))
            .overlay {
                if !isOn { Capsule().strokeBorder(Studio.Palette.hairline, lineWidth: 1) }
            }
            .fixedSize()
    }
}

/// One option of a ``StudioSegmentedControl`` or ``StudioTabBar``.
struct StudioSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String?
    /// Read by VoiceOver instead of `title`: an icon-only segment, or a fuller name
    /// ("Medium queue profile").
    var accessibilityLabel: String?
    /// Read by VoiceOver after the label, e.g. what a queue profile allows.
    var accessibilityValue: String?
    /// The segment's own tooltip, e.g. what a queue profile allows. `nil` leaves only the
    /// control's tooltip, if any.
    var help: String?
    /// Off for an option that does not apply right now (cookies "From browser" with none
    /// captured): dimmed, not hoverable, not selectable.
    var isEnabled = true
    /// Right-click commands for this segment, also offered to VoiceOver as named actions.
    var actions: [StudioSegmentAction] = []

    var id: Value { value }

    init(_ value: Value, title: String, symbol: String? = nil, accessibilityLabel: String? = nil,
         accessibilityValue: String? = nil, help: String? = nil, isEnabled: Bool = true,
         actions: [StudioSegmentAction] = []) {
        self.value = value
        self.title = title
        self.symbol = symbol
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.help = help
        self.isEnabled = isEnabled
        self.actions = actions
    }
}

/// A command on one segment: `StudioSegmentAction(title: L10n.t("Edit Profile…")) { … }`.
struct StudioSegmentAction {
    let title: String
    var isEnabled = true
    let perform: () -> Void
}

/// A segmented control (`.seg`): a sunken track with the selected segment lifted onto a card.
///
///     StudioSegmentedControl(selection: $layout, segments: [
///         StudioSegment(.board, title: "Board", symbol: "rectangle.3.group"),
///         StudioSegment(.list, title: "List", symbol: "list.bullet"),
///     ])
struct StudioSegmentedControl<Value: Hashable>: View {
    enum Size: Sendable { case small, regular }

    @Binding var selection: Value
    let segments: [StudioSegment<Value>]
    var size: Size = .regular
    /// Share the width equally (`.seg.full`).
    var fullWidth = false
    var accessibilityLabel: String?

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                StudioSegmentButton(
                    segment: segment,
                    isSelected: segment.value == selection,
                    size: size,
                    fullWidth: fullWidth,
                    namespace: namespace
                ) {
                    if reduceMotion {
                        selection = segment.value
                    } else {
                        withAnimation(Studio.Motion.spring) { selection = segment.value }
                    }
                }
            }
        }
        .padding(size == .small ? 2 : 3)
        .background(Studio.Palette.segment,
                    in: RoundedRectangle(cornerRadius: size == .small ? 9 : Studio.Radius.segment, style: .continuous))
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}

private struct StudioSegmentButton<Value: Hashable>: View {
    let segment: StudioSegment<Value>
    let isSelected: Bool
    let size: StudioSegmentedControl<Value>.Size
    let fullWidth: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size == .small ? 7 : Studio.Radius.small, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol = segment.symbol {
                    Image(systemName: symbol)
                        .studioFont(.ui, size: size == .small ? 11 : 12, weight: 650)
                }
                if !segment.title.isEmpty {
                    Text(segment.title)
                        .studioFont(.callout.size(size == .small ? 11.5 : 12.5).weight(600))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected || hovered ? Studio.Palette.ink : Studio.Palette.ink2)
            .padding(.horizontal, size == .small ? 9 : 12)
            .frame(minHeight: size == .small ? 22 : 26)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background {
                if isSelected {
                    shape.fill(Studio.Palette.card)
                        .studioElevation(.raised)
                        .matchedGeometryEffect(id: "studio.segment.selection", in: namespace)
                }
            }
            .studioButtonFocusRing(shape: shape)
            // Reaches over the track's padding: a small segment is 22 pt to see, 26 to click.
            .studioHitOutset(2)
        }
        .buttonStyle(.studioPlain)
        .disabled(!segment.isEnabled)
        .opacity(segment.isEnabled ? 1 : 0.45)
        .onHover { hovered = segment.isEnabled && $0 }
        .modifier(StudioOptionalHelp(text: segment.help))
        .modifier(StudioSegmentActions(actions: segment.actions))
        .accessibilityLabel(segment.accessibilityLabel ?? segment.title)
        .accessibilityValue(segment.accessibilityValue ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A segment's commands as a context menu and VoiceOver actions; nothing when it has none, so
/// plain segments get no empty menu.
private struct StudioSegmentActions: ViewModifier {
    let actions: [StudioSegmentAction]

    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            content
                .contextMenu {
                    ForEach(actions.indices, id: \.self) { index in
                        Button(actions[index].title, action: actions[index].perform)
                            .disabled(!actions[index].isEnabled)
                    }
                }
                .accessibilityActions {
                    ForEach(actions.indices.filter { actions[$0].isEnabled }, id: \.self) { index in
                        Button(actions[index].title, action: actions[index].perform)
                    }
                }
        }
    }
}

/// `.help(text)` only when there is text, so a segment without its own tooltip falls back to
/// the one on the control instead of an empty one.
private struct StudioOptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// The detail sheet's tabs (Overview · Files · Network): a full-width segmented control that
/// VoiceOver reads as a tab group.
struct StudioTabBar<Value: Hashable>: View {
    @Binding var selection: Value
    let tabs: [StudioSegment<Value>]
    var accessibilityLabel: String = L10n.t("Tabs")

    var body: some View {
        StudioSegmentedControl(selection: $selection, segments: tabs, size: .regular, fullWidth: true,
                               accessibilityLabel: accessibilityLabel)
            .accessibilityAddTraits(.isTabBar)
    }
}
