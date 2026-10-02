import SwiftUI
import GoelCore

// The Settings window's building blocks: a pane (display title + cards laid out in one or two
// columns), a card (`.sgroup`), and a row (`.srow`) that lights up when the search matches it.

/// One pane: a display title with an optional subtitle and trailing accessory, then its cards.
/// Cards tagged `.settingsColumn(.trailing)` go in the right column when the pane is wide enough;
/// below that width every card stacks in source order.
struct SettingsPane<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    /// Keys whose lock shows the "managed by your organisation" note above the cards.
    var managedKeys: [ManagedPolicy.Key] = []
    /// A single-column pane normally stops at a readable width; this lets it fill the window.
    var fillsWidth = false
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.l) {
            HStack(alignment: .center, spacing: Studio.Space.m) {
                VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                    Text(title)
                        .studioFont(.title1.size(26))
                        .foregroundStyle(Studio.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Studio.Space.m)
                accessory()
            }
            if !managedKeys.isEmpty {
                SettingsManagedNotice(policy: vm.managedPolicy, keys: managedKeys)
            }
            SettingsColumns(spacing: Studio.Space.l,
                            singleColumnMaxWidth: fillsWidth ? .greatestFiniteMagnitude : 760) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsPane where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, managedKeys: [ManagedPolicy.Key] = [],
         fillsWidth: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, managedKeys: managedKeys, fillsWidth: fillsWidth,
                  accessory: { EmptyView() }, content: content)
    }
}

/// Which column a card prefers when the pane has room for two.
enum SettingsColumn: Sendable { case leading, trailing }

private struct SettingsColumnKey: LayoutValueKey {
    static let defaultValue = SettingsColumn.leading
}

extension View {
    /// Puts a card in the pane's right-hand column when there is room for two.
    func settingsColumn(_ column: SettingsColumn) -> some View {
        layoutValue(key: SettingsColumnKey.self, value: column)
    }
}

/// Two top-aligned columns of cards (the mockup's `grid-template-columns: 1fr 1fr`), or one
/// column, capped for readability, when nothing asks for the right column or it would be too
/// narrow.
struct SettingsColumns: Layout {
    var spacing: CGFloat = Studio.Space.l
    var minimumColumnWidth: CGFloat = 330
    var singleColumnMaxWidth: CGFloat = 760

    private struct Plan {
        var frames: [CGRect]
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, plan.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func plan(width proposed: CGFloat?, subviews: Subviews) -> Plan {
        let width = max(0, (proposed?.isFinite == true ? proposed : nil) ?? singleColumnMaxWidth)
        let wantsTwo = subviews.contains { $0[SettingsColumnKey.self] == .trailing }
        let twoColumns = wantsTwo && width >= minimumColumnWidth * 2 + spacing
        guard twoColumns else {
            let columnWidth = min(width, singleColumnMaxWidth)
            var y: CGFloat = 0
            var frames: [CGRect] = []
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
                frames.append(CGRect(x: 0, y: y, width: columnWidth, height: height))
                y += height + spacing
            }
            return Plan(frames: frames, size: CGSize(width: width, height: max(0, y - spacing)))
        }
        let columnWidth = (width - spacing) / 2
        var heights: [CGFloat] = [0, 0]
        var frames: [CGRect] = []
        for subview in subviews {
            let column = subview[SettingsColumnKey.self] == .trailing ? 1 : 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let x = column == 0 ? 0 : columnWidth + spacing
            frames.append(CGRect(x: x, y: heights[column], width: columnWidth, height: height))
            heights[column] += height + spacing
        }
        let height = max(heights[0], heights[1]) - spacing
        return Plan(frames: frames, size: CGSize(width: width, height: max(0, height)))
    }
}

/// A grouped settings card (`.sgroup`): an optional header (glyph, title, trailing accessory),
/// then rows. The first row's top hairline is hidden, as in the mockup.
struct SettingsCard<Accessory: View, Content: View>: View {
    var title: String?
    var symbol: String?
    var footer: String?
    @ViewBuilder var accessory: () -> Accessory
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
                        Spacer(minLength: Studio.Space.s)
                        accessory()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, Studio.Space.ml)
                    .padding(.bottom, Studio.Space.xxs)
                }
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                // Pulls the first row's hairline under the clip.
                .padding(.top, -1)
                .clipped()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioSurface(.card, radius: Studio.Radius.card)
            if let footer {
                Text(footer)
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Studio.Space.xxs)
            }
        }
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(title: String? = nil, symbol: String? = nil, footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, symbol: symbol, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// Free-form content inside a card, with the row padding and (by default) a hairline above.
struct SettingsCardBlock<Content: View>: View {
    var showsDivider = true
    var verticalPadding: CGFloat = Studio.Space.m
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider { StudioDivider() }
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                content()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One setting (`.srow`): title and explanation on the left, the control on the right, a hairline
/// above. Lights up when the Settings search matches its title, and names its control for
/// VoiceOver through `settingRowName`.
///
///     SettingRow("Proxy host", detail: "Hostname or IP of the proxy server.") { SettingsTextField(…) }
///     SettingRow("Launch at login", detail: "Start Goel° when you log in.", isOn: $launch)
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var isIndented = false
    var alignment: VerticalAlignment = .center
    @ViewBuilder var control: () -> Control

    @Environment(\.settingsSearchQuery) private var searchQuery

    init(_ title: String, detail: String? = nil, isIndented: Bool = false,
         alignment: VerticalAlignment = .center, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.isIndented = isIndented
        self.alignment = alignment
        self.control = control
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioDivider()
            HStack(alignment: alignment, spacing: Studio.Space.l) {
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    if !title.isEmpty {
                        Text(title)
                            .studioFont(.bodyStrong)
                            .foregroundStyle(Studio.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Unclamped: a description is the only explanation a setting gets.
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .studioFont(.caption)
                            .foregroundStyle(Studio.Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, isIndented ? 18 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                // The explanation wraps; a control never truncates.
                control()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, Studio.Space.m)
            .frame(minHeight: 52)
            .settingsSearchHighlight(title, query: searchQuery)
        }
        .environment(\.settingRowName, title)
    }
}

extension SettingRow where Control == SettingSwitch {
    /// A row whose control is the Studio switch.
    init(_ title: String, detail: String? = nil, isIndented: Bool = false, isOn: Binding<Bool>) {
        self.init(title, detail: detail, isIndented: isIndented) { SettingSwitch(isOn: isOn) }
    }
}

/// A row of buttons at the foot of a card (the old untitled action rows).
struct SettingsActionRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            StudioDivider()
            HStack(spacing: Studio.Space.s) {
                Spacer(minLength: 0)
                content()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, Studio.Space.sm)
        }
    }
}

private struct SettingsSearchHighlight: ViewModifier {
    let isHit: Bool

    func body(content: Content) -> some View {
        content
            // Drawn behind the row, so lighting up never shifts its content.
            .background {
                if isHit {
                    ZStack(alignment: .leading) {
                        Studio.Palette.accentSoft
                        Studio.Palette.accent.frame(width: 3)
                    }
                    .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// The accent wash a setting gets while the Settings search matches `title`.
    func settingsSearchHighlight(_ title: String, query: String) -> some View {
        modifier(SettingsSearchHighlight(isHit: SettingsSearch.highlights(title, query: query)))
    }

    /// Only `isLocked` keys disable a control; a managed *default* must stay editable.
    @ViewBuilder
    func managed(_ key: ManagedPolicy.Key, _ policy: ManagedPolicy) -> some View {
        if policy.isLocked(key) {
            self.disabled(true)
                .help(AppViewModel.managedFootnote)
                .accessibilityHint(AppViewModel.managedFootnote)
        } else {
            self
        }
    }
}

/// "Some settings here are managed…", shown on a pane only when one of its keys is locked.
struct SettingsManagedNotice: View {
    let policy: ManagedPolicy
    let keys: [ManagedPolicy.Key]

    var body: some View {
        if keys.contains(where: policy.isLocked) {
            StudioNote(tone: .neutral, symbol: "lock.fill",
                       message: L10n.t("Some settings here are managed by your organisation and can’t be changed."))
        }
    }
}

/// A small caption under a control or between rows: a warning, a resolved path, a footnote.
struct SettingsFootnote: View {
    let text: String
    var tone: StudioTone = .neutral
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Studio.Space.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .studioFont(.ui, size: 11.5, weight: 650)
                    .foregroundStyle(tone == .neutral ? Studio.Palette.ink3 : tone.foreground)
                    .accessibilityHidden(true)
            }
            Text(text)
                .studioFont(.caption)
                .foregroundStyle(tone == .neutral ? Studio.Palette.ink3 : tone.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
