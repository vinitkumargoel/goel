import SwiftUI
import GoelCore

/// Statistics (⌘Y): lifetime totals, today's traffic and a 14-day bar chart, as a sheet.
struct StatsView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var stats: TransferStats?

    /// `stats` is for previews and snapshots; the app passes nothing and the sheet loads them.
    init(stats: TransferStats? = nil) {
        _stats = State(initialValue: stats)
    }

    var body: some View {
        StudioSheet(title: L10n.t("Statistics"), symbol: "chart.bar", width: 600) {
            if let stats {
                totals(stats)
                StatsDailyChart(days: stats.lastDays(14))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .accessibilityLabel(L10n.t("Loading statistics"))
            }
        } footer: {
            StudioSheetFooter(primaryTitle: L10n.t("Done")) { vm.isStatsPresented = false }
        }
        .task {
            guard stats == nil else { return }
            stats = await vm.fetchStats()
        }
    }

    private func totals(_ stats: TransferStats) -> some View {
        let today = stats.today()
        let finishedToday = vm.tasks.filter { task in
            task.status == .completed && task.completedAt.map(Calendar.current.isDateInToday) == true
        }.count
        let columns = Array(repeating: GridItem(.flexible(), spacing: Studio.Space.sm), count: 3)
        return LazyVGrid(columns: columns, spacing: Studio.Space.sm) {
            StatsTile(bytes: stats.totalDownloadedBytes, caption: L10n.t("Downloaded"),
                      spoken: A11y.bytes(stats.totalDownloadedBytes))
            StatsTile(bytes: stats.totalUploadedBytes, caption: L10n.t("Uploaded"),
                      spoken: A11y.bytes(stats.totalUploadedBytes))
            StatsTile(value: stats.completedCount.formatted(), caption: L10n.t("Completed"),
                      spoken: L10n.t("%d downloads", stats.completedCount))
            StatsTile(bytes: today.down, caption: L10n.t("Today ↓"), tone: .accent,
                      spokenLabel: L10n.t("Downloaded today"), spoken: A11y.bytes(today.down))
            StatsTile(bytes: today.up, caption: L10n.t("Today ↑"), tone: .upload,
                      spokenLabel: L10n.t("Uploaded today"), spoken: A11y.bytes(today.up))
            StatsTile(value: finishedToday.formatted(), caption: L10n.t("Finished today"),
                      spoken: L10n.t("%d downloads", finishedToday))
        }
    }
}

/// A statistic tile (`.stat`), optionally tinted (today's traffic).
private struct StatsTile: View {
    let value: String
    var unit: String?
    let caption: String
    var tone: StudioTone = .neutral
    var spokenLabel: String?
    var spoken: String

    init(value: String, caption: String, tone: StudioTone = .neutral, spokenLabel: String? = nil, spoken: String) {
        self.value = value
        self.caption = caption
        self.tone = tone
        self.spokenLabel = spokenLabel
        self.spoken = spoken
    }

    init(bytes: Int64, caption: String, tone: StudioTone = .neutral, spokenLabel: String? = nil, spoken: String) {
        let parts = StatsUnits.split(bytes.byteString)
        self.init(value: parts.value, caption: caption, tone: tone, spokenLabel: spokenLabel, spoken: spoken)
        unit = parts.unit
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: Studio.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Studio.Space.hair) {
                Text(value)
                    .studioFont(.stat)
                    .foregroundStyle(tone == .neutral ? Studio.Palette.ink : tone.foreground)
                if let unit {
                    Text(unit).studioFont(.bodyStrong).foregroundStyle(Studio.Palette.ink2)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(caption)
                .studioFont(.caption.weight(600))
                .foregroundStyle(Studio.Palette.ink3)
        }
        .padding(Studio.Space.ml)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tone == .neutral ? Studio.Palette.well : tone.background))
        .overlay {
            if tone == .neutral { shape.strokeBorder(Studio.Palette.hairline, lineWidth: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel ?? caption)
        .accessibilityValue(spoken)
    }
}

enum StatsUnits {
    /// "1.84 TB" → ("1.84", "TB"); a string without a space stays whole.
    static func split(_ text: String) -> (value: String, unit: String?) {
        guard let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) else { return (text, nil) }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

/// "Last 14 days": a stacked bar per day (↓ accent on top of ↑ upload), a y-axis and day numbers.
private struct StatsDailyChart: View {
    let days: [(day: String, totals: TransferStats.DayTotals)]

    private static let chartHeight: CGFloat = 130

    var body: some View {
        let peak = max(days.map { $0.totals.down + $0.totals.up }.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            HStack(spacing: Studio.Space.s) {
                WindowsEyebrow(L10n.t("Last 14 days"))
                Spacer(minLength: Studio.Space.s)
                StudioLegendItem(L10n.t("Downloaded"), color: Studio.Palette.accent)
                StudioLegendItem(L10n.t("Uploaded"), color: Studio.Palette.upload)
            }
            HStack(alignment: .top, spacing: Studio.Space.s) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(peak.byteString)
                    Spacer(minLength: 0)
                    Text((peak / 2).byteString)
                    Spacer(minLength: 0)
                    Text(verbatim: "0")
                }
                .studioFont(.monoSmall.size(10))
                .foregroundStyle(Studio.Palette.ink3)
                .frame(width: 52, height: Self.chartHeight, alignment: .trailing)
                .accessibilityHidden(true)
                VStack(spacing: Studio.Space.xs) {
                    bars(peak: peak)
                    HStack(spacing: Studio.Space.xs) {
                        ForEach(days, id: \.day) { entry in
                            Text(String(entry.day.suffix(2)))
                                .studioFont(.monoSmall.size(9.5))
                                .foregroundStyle(Studio.Palette.ink3)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Daily transfer totals, last 14 days"))
    }

    private func bars(peak: Int64) -> some View {
        let today = TransferStats.dayKey(for: Date())
        return HStack(alignment: .bottom, spacing: Studio.Space.xs) {
            ForEach(days, id: \.day) { entry in
                let down = CGFloat(Double(entry.totals.down) / Double(peak)) * Self.chartHeight
                let up = CGFloat(Double(entry.totals.up) / Double(peak)) * Self.chartHeight
                VStack(spacing: Studio.Space.hair) {
                    Spacer(minLength: 0)
                    if entry.totals.down + entry.totals.up == 0 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Studio.Palette.track)
                            .frame(height: 3)
                    } else {
                        if down > 0 {
                            UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 2,
                                                   bottomTrailingRadius: 2, topTrailingRadius: 5,
                                                   style: .continuous)
                                .fill(Studio.Palette.accent)
                                .frame(height: max(2, down))
                        }
                        if up > 0 {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Studio.Palette.upload)
                                .frame(height: max(2, up))
                        }
                    }
                }
                .padding(entry.day == today ? 1 : 0)
                .background {
                    if entry.day == today {
                        RoundedRectangle(cornerRadius: Studio.Radius.badge, style: .continuous)
                            .fill(Studio.Palette.accentSoft)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.chartHeight, alignment: .bottom)
                .help(L10n.t("%1$@: ↓ %2$@ · ↑ %3$@", entry.day,
                             entry.totals.down.byteString, entry.totals.up.byteString))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.day)
                .accessibilityValue(A11y.sentence(L10n.t("downloaded %@", A11y.bytes(entry.totals.down)),
                                                  L10n.t("uploaded %@", A11y.bytes(entry.totals.up))))
            }
        }
        .frame(height: Self.chartHeight)
    }
}
