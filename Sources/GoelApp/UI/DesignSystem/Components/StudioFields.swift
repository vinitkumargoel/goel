import SwiftUI
import GoelCore

/// The text-field chrome (`.field`): field fill, strong hairline, accent rim and halo when focused.
/// Use as a `TextFieldStyle`: `TextField("Name", text: $name).textFieldStyle(.studio)`.
struct StudioTextFieldStyle: TextFieldStyle {
    var size: StudioFieldSize = .regular
    /// Overrides the size's text style, e.g. `.monoBody` for a digest or a path.
    var font: Studio.TextStyle?
    /// Draws the rim in the warning colour while the value doesn't parse.
    var isInvalid = false

    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        StudioFocusedField(size: size, font: font, isInvalid: isInvalid) { focus in
            configuration
                .textFieldStyle(.plain)
                .focused(focus)
        }
    }
}

extension TextFieldStyle where Self == StudioTextFieldStyle {
    static var studio: StudioTextFieldStyle { StudioTextFieldStyle() }
    static func studio(size: StudioFieldSize = .regular, font: Studio.TextStyle? = nil,
                       isInvalid: Bool = false) -> StudioTextFieldStyle {
        StudioTextFieldStyle(size: size, font: font, isInvalid: isInvalid)
    }
}

enum StudioFieldSize: Sendable {
    case small, regular

    var height: CGFloat { self == .small ? 30 : 36 }
    var radius: CGFloat { self == .small ? Studio.Radius.small : Studio.Radius.control }
    var text: Studio.TextStyle { self == .small ? .body.size(12.5) : .body }
}

/// Wraps any input in Studio field chrome and tracks its focus.
struct StudioFocusedField<Content: View>: View {
    var size: StudioFieldSize = .regular
    var font: Studio.TextStyle?
    var isInvalid = false
    @ViewBuilder var content: (FocusState<Bool>.Binding) -> Content

    @FocusState private var focused: Bool

    init(size: StudioFieldSize = .regular, font: Studio.TextStyle? = nil, isInvalid: Bool = false,
         @ViewBuilder content: @escaping (FocusState<Bool>.Binding) -> Content) {
        self.size = size
        self.font = font
        self.isInvalid = isInvalid
        self.content = content
    }

    var body: some View {
        content($focused)
            .studioFont(font ?? size.text)
            .foregroundStyle(Studio.Palette.ink)
            .padding(.horizontal, Studio.Space.m)
            .frame(minHeight: size.height)
            .modifier(StudioFieldChrome(isFocused: focused, radius: size.radius, isInvalid: isInvalid))
    }
}

/// The field look on its own, for custom inputs (a stepper with a unit, a picker row).
struct StudioFieldChrome: ViewModifier {
    var isFocused: Bool
    var radius: CGFloat = Studio.Radius.control
    /// A value that doesn't parse: warning rim (and halo while focused).
    var isInvalid = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let rim = isInvalid ? Studio.Palette.warn : isFocused ? Studio.Palette.accent : Studio.Palette.hairlineStrong
        content
            .background(shape.fill(Studio.Palette.field))
            .overlay(shape.strokeBorder(rim, lineWidth: 1))
            .background {
                if isFocused {
                    shape.inset(by: -3).fill(isInvalid ? Studio.Palette.warnSoft : Studio.Palette.accentSoft)
                }
            }
    }
}

/// A search field: magnifier, placeholder, a clear button once there is text. Esc clears it.
struct StudioSearchField: View {
    @Binding var text: String
    var placeholder: String = L10n.t("Search")
    var size: StudioFieldSize = .regular
    var onSubmit: (() -> Void)?

    var body: some View {
        StudioFocusedField(size: size) { focus in
            HStack(spacing: Studio.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(StudioFonts.font(.ui, size: size == .small ? 12 : 13, weight: 600))
                    .foregroundStyle(Studio.Palette.ink3)
                    .accessibilityHidden(true)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .onSubmit { onSubmit?() }
                    .onExitCommand { text = "" }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Studio.Palette.ink3)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("Clear"))
                    .accessibilityLabel(L10n.t("Clear"))
                }
            }
        }
    }
}

/// The omnibox (`.omni`): one big field for links, magnets, search and commands, with optional
/// suggestion rows below a dashed rule (the copied-link suggestion, palette results).
///
///     StudioOmnibox(text: $query, placeholder: "Paste a link, magnet or stream — or search",
///                   onSubmit: submit) {
///         StudioOmniboxSuggestion { … }
///     }
struct StudioOmnibox<Suggestions: View>: View {
    @Binding var text: String
    var placeholder: String
    var symbol: String = "plus"
    var shortcutHint: String? = "⌘K"
    /// Drives focus from outside (⌘K, ⌘L). Optional.
    var isFocused: FocusState<Bool>.Binding?
    var onSubmit: () -> Void = {}
    @ViewBuilder var suggestions: () -> Suggestions

    @FocusState private var ownFocus: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.omnibox, style: .continuous)
        let focused = isFocused?.wrappedValue ?? ownFocus
        VStack(spacing: 0) {
            HStack(spacing: Studio.Space.m) {
                Image(systemName: symbol)
                    .font(StudioFonts.font(.ui, size: 18, weight: 650))
                    .foregroundStyle(Studio.Palette.accent)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                field
                    .textFieldStyle(.plain)
                    .studioFont(.omnibox)
                    .foregroundStyle(Studio.Palette.ink)
                    .onSubmit(onSubmit)
                if let shortcutHint, text.isEmpty {
                    StudioKeyCaps(shortcutHint)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, Studio.Space.sm)
            .frame(minHeight: 58)
            suggestions()
        }
        .background(shape.fill(Studio.Palette.card).studioElevation(focused ? .floating : .card))
        .overlay(shape.strokeBorder(focused ? Studio.Palette.accentLine : Studio.Palette.cardEdge, lineWidth: 1))
        .background {
            if focused { shape.inset(by: -4).fill(Studio.Palette.accentSoft) }
        }
    }

    @ViewBuilder private var field: some View {
        if let isFocused {
            TextField(placeholder, text: $text).focused(isFocused)
        } else {
            TextField(placeholder, text: $text).focused($ownFocus)
        }
    }
}

extension StudioOmnibox where Suggestions == EmptyView {
    init(text: Binding<String>, placeholder: String, symbol: String = "plus", shortcutHint: String? = "⌘K",
         isFocused: FocusState<Bool>.Binding? = nil, onSubmit: @escaping () -> Void = {}) {
        self.init(text: text, placeholder: placeholder, symbol: symbol, shortcutHint: shortcutHint,
                  isFocused: isFocused, onSubmit: onSubmit, suggestions: { EmptyView() })
    }
}

/// One suggestion strip under the omnibox input (`.omni-sug`): dashed top rule, then content.
struct StudioOmniboxSuggestion<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Line()
                .stroke(Studio.Palette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
            HStack(spacing: Studio.Space.m) { content() }
                .padding(.vertical, Studio.Space.sm)
                .padding(.leading, Studio.Space.ml)
                .padding(.trailing, Studio.Space.sm)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
