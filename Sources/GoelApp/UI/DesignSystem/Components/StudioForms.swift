import SwiftUI
import GoelCore

/// An uppercase section label (`.eyebrow` + `.sect-h`), with optional trailing detail.
///
///     StudioSectionHeader("Recent throughput", detail: "peak 14.2 MB/s")
struct StudioSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            Text(title)
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Studio.Space.s)
            trailing()
        }
    }
}

extension StudioSectionHeader where Trailing == AnyView {
    /// `detail` is drawn in faint mono, the mockup's "peak 14.2 MB/s" / "last 60 s".
    init(_ title: String, detail: String? = nil) {
        self.init(title) {
            AnyView(
                Group {
                    if let detail {
                        Text(detail).studioFont(.monoSmall).foregroundStyle(Studio.Palette.ink3)
                    }
                }
            )
        }
    }
}

/// One settings row (`.srow`): title and optional explanation on the left, the control on the
/// right, a hairline above. Put rows inside a ``StudioFormCard``.
///
///     StudioFormRow("Download folder", subtitle: "Where new files go") {
///         Button("Choose…") { … }.buttonStyle(.studio(size: .small))
///     }
struct StudioFormRow<Control: View>: View {
    let title: String
    var subtitle: String?
    /// Indents the row under the one above it (`.srow .indent`), for a dependent option.
    var isIndented = false
    @ViewBuilder var control: () -> Control

    init(_ title: String, subtitle: String? = nil, isIndented: Bool = false,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.isIndented = isIndented
        self.control = control
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioDivider()
            HStack(spacing: Studio.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                    if let subtitle {
                        Text(subtitle)
                            .studioFont(.caption)
                            .foregroundStyle(Studio.Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, isIndented ? 18 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                control()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, Studio.Space.m)
            .frame(minHeight: 52)
        }
    }
}

/// A grouped settings card (`.sgroup`): optional header, then rows separated by hairlines. The
/// first row's top hairline is hidden, as in the mockup (`.sgroup-h + .srow { border-top: 0 }`).
///
///     StudioFormCard(title: "Downloads", symbol: "arrow.down.circle") {
///         StudioToggleRow("Start downloads automatically", isOn: $auto)
///         StudioFormRow("Simultaneous downloads") { … }
///     }
struct StudioFormCard<Content: View>: View {
    var title: String?
    var symbol: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    HStack(spacing: Studio.Space.sm) {
                        if let symbol {
                            Image(systemName: symbol)
                                .studioFont(.ui, size: 14, weight: 650)
                                .foregroundStyle(Studio.Palette.accent)
                                .accessibilityHidden(true)
                        }
                        Text(title)
                            .studioFont(.title3)
                            .foregroundStyle(Studio.Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, Studio.Space.ml)
                    .padding(.bottom, Studio.Space.xxs)
                }
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                // Pulls the first row's hairline outside the clip.
                .padding(.top, -1)
                .clipped()
            }
            .studioSurface(.card, radius: Studio.Radius.card)
            if let footer {
                Text(footer)
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .padding(.horizontal, Studio.Space.xxs)
            }
        }
    }
}

/// A form row whose control is a Studio switch.
struct StudioToggleRow: View {
    let title: String
    var subtitle: String?
    var isIndented = false
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, subtitle: String? = nil, isIndented: Bool = false, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.isIndented = isIndented
        _isOn = isOn
    }

    var body: some View {
        StudioFormRow(title, subtitle: subtitle, isIndented: isIndented) {
            // The row already shows the title; the switch carries it only for VoiceOver.
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.studioSwitch)
                .accessibilityLabel(title)
        }
        // A click on the title or subtitle flips the switch, as on a native toggle's label.
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOn.toggle() } }
    }
}

/// The Studio switch (`.toggle`): 34×20 track, accent when on.
struct StudioSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        StudioSwitchBody(configuration: configuration)
    }
}

private struct StudioSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            // The label flips the switch too, as a native toggle's does.
            configuration.label
                .studioFont(.body)
                .foregroundStyle(Studio.Palette.ink)
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { toggle() } }
            Button(action: toggle) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Studio.Palette.accent : Studio.Palette.hairlineStrong)
                    Circle()
                        .fill(Studio.Palette.card)
                        .studioElevation(.raised)
                        .padding(2)
                }
                .frame(width: 34, height: 20)
                .studioButtonFocusRing(shape: Capsule())
                // 34 × 20 to see, 38 × 24 to click.
                .studioHitOutset(2)
            }
            .buttonStyle(.studioPlain)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }

    private func toggle() {
        if reduceMotion { configuration.isOn.toggle() } else {
            withAnimation(Studio.Motion.quick) { configuration.isOn.toggle() }
        }
    }
}

/// The Studio checkbox (`.check`), with the mixed state drawn as a bar.
struct StudioCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Studio.Space.s) {
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                ZStack {
                    if configuration.isOn || configuration.isMixed {
                        shape.fill(Studio.Palette.accent)
                        Image(systemName: configuration.isMixed ? "minus" : "checkmark")
                            .studioFont(.ui, size: 10, weight: 800)
                            .foregroundStyle(Studio.Palette.onAccent)
                    } else {
                        shape.fill(Studio.Palette.card)
                        shape.strokeBorder(Studio.Palette.hairlineStrong, lineWidth: 1.5)
                    }
                }
                .frame(width: 17, height: 17)
                configuration.label
                    .studioFont(.body)
                    .foregroundStyle(Studio.Palette.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == StudioSwitchToggleStyle {
    static var studioSwitch: StudioSwitchToggleStyle { StudioSwitchToggleStyle() }
}

extension ToggleStyle where Self == StudioCheckboxToggleStyle {
    static var studioCheckbox: StudioCheckboxToggleStyle { StudioCheckboxToggleStyle() }
}
