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
}

/// A 7×24 grid painted with profile colours. Pick a brush, then click or drag a rectangle;
/// "Leave alone" erases. Unpainted hours keep whatever profile is active.
struct WeeklyProfileGrid: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var brush = ""
    @State private var dragStart: (day: Int, hour: Int)?
    @State private var draft: [String]?

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
            HStack(spacing: 2) {
                ForEach(names, id: \.self) { name in
                    brushChip(name)
                }
                brushChip("")
            }
            .padding(3)
            .background(Studio.Palette.segment, in: RoundedRectangle(cornerRadius: Studio.Radius.segment, style: .continuous))
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
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(style.fill)
                        .overlay {
                            if let rim = style.rim {
                                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(rim, lineWidth: 1)
                            }
                        }
                        .frame(width: 10, height: 10)
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
        return GeometryReader { proxy in
            Canvas { context, size in
                Self.draw(cells: cells, names: names, in: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(paintGesture(size: proxy.size))
        }
        .frame(height: Self.rowHeight * 7)
        .help(L10n.t("Paint hours with a traffic profile. A manual change holds until the next painted hour."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Weekly profile schedule"))
        .accessibilityValue(accessibilitySummary(cells))
    }

    private static func draw(cells: [String], names: [String], in context: GraphicsContext, size: CGSize) {
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
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4.5, style: .continuous),
                                   with: .color(rim), lineWidth: 1)
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
