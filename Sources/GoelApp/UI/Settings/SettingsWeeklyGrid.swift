import SwiftUI
import GoelCore

/// Runs of one profile within a day, for VoiceOver and the grid's tooltip: "00–06 Night, 18–24 Fast".
enum ProfileScheduleSummary {
    struct Run: Equatable {
        let start: Int
        let end: Int   // exclusive
        let profile: String
    }

    static func runs(day: Int, grid: [String]) -> [Run] {
        let cells = ProfileSchedule.normalized(grid)
        var out: [Run] = []
        var hour = 0
        while hour < 24 {
            let name = cells[day * 24 + hour]
            var end = hour + 1
            while end < 24, cells[day * 24 + end] == name { end += 1 }
            if !name.isEmpty { out.append(Run(start: hour, end: end, profile: name)) }
            hour = end
        }
        return out
    }

    static func describe(day: Int, grid: [String]) -> String {
        let runs = runs(day: day, grid: grid)
        guard !runs.isEmpty else { return L10n.t("No scheduled profile") }
        return runs.map { String(format: "%02d–%02d ", $0.start, $0.end) + $0.profile }
            .joined(separator: ", ")
    }

    /// The letter drawn in a profile's cells, so the grid does not rely on colour: the shortest
    /// prefix (1–2 characters) no other profile shares, else the profile's number in the list.
    static func glyphs(for names: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for (index, name) in names.enumerated() {
            let others = names.enumerated().filter { $0.offset != index }.map { $0.element.uppercased() }
            let upper = name.uppercased()
            let prefix = (1...2).lazy.map { String(upper.prefix($0)) }
                .first { candidate in !candidate.isEmpty && !others.contains { $0.hasPrefix(candidate) } }
            out[name] = prefix ?? String(index + 1)
        }
        return out
    }
}

/// The weekly grid's keyboard cursor: one hour cell. Arrows step by an hour or a day and stop
/// at the edges; VoiceOver's adjust steps hour by hour through the whole week.
struct WeeklyGridCursor: Equatable {
    var day = 0
    var hour = 0

    func moved(days: Int = 0, hours: Int = 0) -> WeeklyGridCursor {
        WeeklyGridCursor(day: min(6, max(0, day + days)), hour: min(23, max(0, hour + hours)))
    }

    /// One hour on, wrapping into the next (or previous) day; stops at the week's ends.
    func stepped(by offset: Int) -> WeeklyGridCursor {
        let slot = min(ProfileSchedule.slotCount - 1, max(0, day * 24 + hour + offset))
        return WeeklyGridCursor(day: slot / 24, hour: slot % 24)
    }
}

/// A 7×24 grid painted with profile colours. Pick a brush, then click or drag a rectangle;
/// "Leave alone" erases. Unpainted hours keep whatever profile is active.
struct WeeklyProfileGrid: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var brush = ""
    @State private var dragStart: (day: Int, hour: Int)?
    @State private var draft: [String]?
    @State private var cursor = WeeklyGridCursor()
    @FocusState private var gridFocused: Bool

    private static let labelWidth: CGFloat = 38
    private static let rowHeight: CGFloat = 25
    private static let gap: CGFloat = 3

    private var names: [String] { vm.settings.profiles.map(\.name) }
    private var grid: [String] { draft ?? ProfileSchedule.normalized(vm.settings.profileSchedule) }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            brushes
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                hourLabels
                HStack(spacing: 0) {
                    dayLabels
                    canvas
                }
            }
        }
        .onAppear { if brush.isEmpty { brush = names.first ?? "" } }
    }

    /// The fill and rim for a profile's cells and its brush swatch, by its place in the list.
    static func style(for profile: String, in names: [String]) -> (fill: Color, rim: Color?) {
        guard let index = names.firstIndex(of: profile) else { return (Studio.Palette.segment, nil) }
        let styles: [(Color, Color?)] = [
            (Studio.Palette.uploadSoft, Studio.Palette.upload),
            (Studio.Palette.accentSoft, Studio.Palette.accentLine),
            (Studio.Palette.accent, nil),
            (Studio.Palette.warnSoft, Studio.Palette.warn),
            (Studio.Palette.infoSoft, Studio.Palette.info),
            (Studio.Palette.goodSoft, Studio.Palette.good),
            (Studio.Palette.badSoft, Studio.Palette.bad),
        ]
        let style = styles[index % styles.count]
        return (style.0, style.1)
    }

    private var brushes: some View {
        HStack(spacing: Studio.Space.s) {
            Text(L10n.t("Brush"))
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityHidden(true)
            HStack(spacing: Studio.Space.hair) {
                ForEach(names, id: \.self) { name in
                    brushChip(name)
                }
                brushChip("")
            }
            .padding(3)
            .background(Studio.Palette.segment,
                        in: RoundedRectangle(cornerRadius: Studio.Radius.segment, style: .continuous))
            Spacer(minLength: Studio.Space.s)
            Button(L10n.t("Clear All")) { commit(Array(repeating: "", count: ProfileSchedule.slotCount)) }
                .buttonStyle(.studio(.ghost, size: .small))
        }
    }

    private func brushChip(_ name: String) -> some View {
        let selected = brush == name
        let style = Self.style(for: name, in: names)
        return Button { brush = name } label: {
            HStack(spacing: 5) {
                if !name.isEmpty {
                    // The swatch carries the letter its cells show.
                    Text(ProfileScheduleSummary.glyphs(for: names)[name] ?? "")
                        .font(StudioFonts.font(.ui, size: 8.5, weight: 700))
                        .foregroundStyle(style.rim == nil ? Studio.Palette.onAccent : Studio.Palette.ink)
                        .padding(.horizontal, 2)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(style.fill, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay {
                            if let rim = style.rim {
                                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(rim, lineWidth: 1)
                            }
                        }
                        .accessibilityHidden(true)
                }
                Text(name.isEmpty ? L10n.t("Leave alone") : name)
                    .studioFont(.callout)
                    .foregroundStyle(selected ? Studio.Palette.ink : Studio.Palette.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, Studio.Space.sm)
            .frame(height: 24)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
                        .fill(Studio.Palette.card)
                        .studioElevation(.raised)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.isEmpty ? L10n.t("Brush: leave alone") : L10n.t("Brush: %@", name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var hourLabels: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.labelWidth, height: 1)
            GeometryReader { proxy in
                ForEach(Array(stride(from: 0, to: 24, by: 3)), id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .studioFont(.monoSmall.size(10))
                        .foregroundStyle(Studio.Palette.ink3)
                        .position(x: proxy.size.width * (CGFloat(hour) + 0.5) / 24, y: 6)
                }
            }
            .frame(height: 12)
        }
        .accessibilityHidden(true)
    }

    private var dayLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { day in
                Text(Calendar.current.shortWeekdaySymbols[day])
                    .studioFont(.monoSmall.size(10))
                    .foregroundStyle(Studio.Palette.ink3)
                    .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private var canvas: some View {
        let cells = grid
        let names = self.names
        let cursor: WeeklyGridCursor? = gridFocused ? self.cursor : nil
        let painted = GeometryReader { proxy in
            Canvas { context, size in
                Self.draw(cells: cells, names: names, cursor: cursor, in: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(paintGesture(size: proxy.size))
        }
        .frame(height: Self.rowHeight * 7)
        .help(L10n.t("Paint hours with a traffic profile. A manual change holds until the next painted hour."))
        return keyboardAndVoiceOver(painted, cells: cells)
    }

    /// The keyboard path: a cell cursor drawn as the focus ring, painted with the brush; VoiceOver
    /// adjusts the same cursor and paints through actions.
    private func keyboardAndVoiceOver(_ content: some View, cells: [String]) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress { handleKey($0) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("Weekly profile schedule"))
            .accessibilityValue(cellDescription(cells) + ". " + accessibilitySummary(cells))
            .accessibilityHint(L10n.t("Arrow keys move between hours. Space paints the hour with the brush, "
                + "Delete clears it. Shift with an arrow paints as it moves."))
            .accessibilityAdjustableAction { direction in
                moveCursor(to: cursor.stepped(by: direction == .increment ? 1 : -1))
            }
            .accessibilityAction(named: L10n.t("Paint Hour")) { paintCursor(with: brush) }
            .accessibilityAction(named: L10n.t("Clear Hour")) { paintCursor(with: "") }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let painting = press.modifiers.contains(.shift)
        let next: WeeklyGridCursor
        switch press.key {
        case .leftArrow: next = cursor.moved(hours: -1)
        case .rightArrow: next = cursor.moved(hours: 1)
        case .upArrow: next = cursor.moved(days: -1)
        case .downArrow: next = cursor.moved(days: 1)
        case .space, .return:
            paintCursor(with: brush)
            return .handled
        case .delete, .deleteForward:
            paintCursor(with: "")
            return .handled
        default:
            return .ignored
        }
        moveCursor(to: next)
        if painting { paintCursor(with: brush) }
        return .handled
    }

    private func moveCursor(to next: WeeklyGridCursor) {
        cursor = next
        A11yAnnouncer.announce(cellDescription(grid))
    }

    private func paintCursor(with profile: String) {
        let at = (day: cursor.day, hour: cursor.hour)
        commit(ProfileSchedule.painting(ProfileSchedule.normalized(vm.settings.profileSchedule),
                                        from: at, to: at, with: profile))
    }

    /// "Monday 09:00, Night": the cursor's hour and what it is painted with.
    private func cellDescription(_ cells: [String]) -> String {
        let profile = cells[cursor.day * 24 + cursor.hour]
        return A11y.sentence(Calendar.current.weekdaySymbols[cursor.day] + " " + String(format: "%02d:00", cursor.hour),
                             profile.isEmpty ? L10n.t("No scheduled profile") : profile)
    }

    private static func draw(cells: [String], names: [String], cursor: WeeklyGridCursor?,
                             in context: GraphicsContext, size: CGSize) {
        let glyphs = ProfileScheduleSummary.glyphs(for: names)
        let w = size.width / 24
        let h = size.height / 7
        for day in 0..<7 {
            for hour in 0..<24 {
                let rect = CGRect(x: CGFloat(hour) * w + gap / 2, y: CGFloat(day) * h + gap / 2,
                                  width: w - gap, height: h - gap)
                let path = Path(roundedRect: rect, cornerRadius: 5, style: .continuous)
                let style = style(for: cells[day * 24 + hour], in: names)
                context.fill(path, with: .color(style.fill))
                if let rim = style.rim {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4.5,
                                        style: .continuous),
                                   with: .color(rim), lineWidth: 1)
                }
                // A letter per profile, so the schedule reads without telling colours apart.
                let name = cells[day * 24 + hour]
                if let glyph = glyphs[name] {
                    let text = Text(glyph)
                        .font(StudioFonts.font(.ui, size: min(10, rect.width * 0.55), weight: 700))
                        .foregroundColor(style.rim == nil ? Studio.Palette.onAccent : Studio.Palette.ink)
                    context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
                }
                if let cursor, cursor.day == day, cursor.hour == hour {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 6, style: .continuous),
                                   with: .color(Studio.Palette.focusRing), lineWidth: 2.5)
                }
            }
        }
    }

    private func paintGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? Self.cell(at: value.startLocation, size: size)
                dragStart = start
                let end = Self.cell(at: value.location, size: size)
                cursor = WeeklyGridCursor(day: end.day, hour: end.hour)
                let base = ProfileSchedule.normalized(vm.settings.profileSchedule)
                draft = ProfileSchedule.painting(base, from: start, to: end, with: brush)
            }
            .onEnded { _ in
                if let draft { commit(draft) }
                draft = nil
                dragStart = nil
            }
    }

    static func cell(at point: CGPoint, size: CGSize) -> (day: Int, hour: Int) {
        let hour = Int((point.x / max(1, size.width)) * 24)
        let day = Int((point.y / max(1, size.height)) * 7)
        return (min(6, max(0, day)), min(23, max(0, hour)))
    }

    private func commit(_ cells: [String]) {
        let pruned = ProfileSchedule.pruned(cells, keeping: Set(names))
        vm.update { $0.profileSchedule = pruned }
    }

    private func accessibilitySummary(_ cells: [String]) -> String {
        (0..<7).map { day in
            Calendar.current.weekdaySymbols[day] + ": " + ProfileScheduleSummary.describe(day: day, grid: cells)
        }
        .joined(separator: ". ")
    }
}
