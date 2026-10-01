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

/// Settings › Scheduler: a 7×24 grid painted with profile colours. Pick a brush, then click or
/// drag a rectangle; "Leave alone" erases. Unpainted hours keep whatever profile is active.
struct WeeklyProfileGrid: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var brush = ""
    @State private var dragStart: (day: Int, hour: Int)?
    @State private var draft: [String]?

    private static let labelWidth: CGFloat = 34
    private static let cellHeight: CGFloat = 18

    private var names: [String] { vm.settings.profiles.map(\.name) }
    private var grid: [String] { draft ?? ProfileSchedule.normalized(vm.settings.profileSchedule) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            brushes
            hourLabels
            HStack(spacing: 0) {
                dayLabels
                canvas
            }
        }
        .onAppear { if brush.isEmpty { brush = names.first ?? "" } }
    }

    static func color(for profile: String, in names: [String]) -> Color {
        guard let index = names.firstIndex(of: profile) else { return .clear }
        let palette: [Color] = [Theme.accent, Theme.green, Theme.orange, Theme.purple, Theme.teal, Theme.indigo, Theme.red]
        return palette[index % palette.count]
    }

    private var brushes: some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                brushChip(name, color: Self.color(for: name, in: names))
            }
            brushChip("", color: Color.secondary.opacity(0.25))
            Spacer()
            Button(L10n.t("Clear All")) { commit(Array(repeating: "", count: ProfileSchedule.slotCount)) }
                .buttonStyle(.link)
        }
    }

    private func brushChip(_ name: String, color: Color) -> some View {
        let selected = brush == name
        return Button { brush = name } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
                Text(name.isEmpty ? L10n.t("Leave alone") : name)
                    .scaledFont(size: Theme.TextSize.meta, weight: selected ? .semibold : .regular)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().stroke(selected ? Theme.accent : Color.clear, lineWidth: 1.5))
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
                        .scaledFont(size: Theme.TextSize.micro, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                        .position(x: proxy.size.width * CGFloat(hour) / 24 + 7, y: 6)
                }
            }
            .frame(height: 12)
        }
        .a11yDecorative()
    }

    private var dayLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { day in
                Text(Calendar.current.shortWeekdaySymbols[day])
                    .scaledFont(size: Theme.TextSize.micro)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, height: Self.cellHeight, alignment: .leading)
            }
        }
        .a11yDecorative()
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
        .frame(height: Self.cellHeight * 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Weekly profile schedule"))
        .accessibilityValue(accessibilitySummary(cells))
    }

    private static func draw(cells: [String], names: [String], in context: GraphicsContext, size: CGSize) {
        let w = size.width / 24
        let h = size.height / 7
        for day in 0..<7 {
            for hour in 0..<24 {
                let rect = CGRect(x: CGFloat(hour) * w + 0.5, y: CGFloat(day) * h + 0.5,
                                  width: w - 1, height: h - 1)
                let name = cells[day * 24 + hour]
                let fill = name.isEmpty ? Color.primary.opacity(0.06) : color(for: name, in: names)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
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
