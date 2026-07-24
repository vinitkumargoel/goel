import SwiftUI

/// Debug surface that renders every design token at true size, so a screenshot proves the
/// values match `visual.html` rather than merely compiling.
///
/// Screenshot it in both appearances. Ember must read warm-orange on black and visibly deeper
/// on white; if the two look identical, the adaptive colours are wired wrong.
public struct SwatchView: View {

    @Environment(\.colorScheme) private var colorScheme
    @State private var switchOn = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                brandSection
                structureSection
                semanticSection
                metricSection
                typeSection
                formatterSection
                footer
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Color.ground.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("T02 · Design tokens")
                .font(Theme.Typo.sectionLabel)
                .tracking(Theme.Typo.sectionTracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Color.ember)
            Text("Goel° swatches")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.Color.label1)
            Text("\(colorScheme == .dark ? "Dark" : "Light") appearance · values lifted from visual.html")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Color.label2)
        }
    }

    private var footer: some View {
        Text("Semantic colours are reserved: green = verified, red = failure, orange = caution. Never decoration.")
            .font(Theme.Typo.caption)
            .foregroundStyle(Theme.Color.label3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    // MARK: - Colour sections

    private var brandSection: some View {
        Group1(title: "Brand") {
            SwatchGrid(chips: [
                Chip("ember", Theme.Color.ember, "active transfer · CTA · progress"),
                Chip("emberBright", Theme.Color.emberBright, "gradient leading stop"),
                Chip("instrument", Theme.Color.instrument, "SFTP · secondary data")
            ])
            GradientStrip()
        }
    }

    private var structureSection: some View {
        Group1(title: "Ground, elevation, labels") {
            SwatchGrid(chips: [
                Chip("ground", Theme.Color.ground, "OLED base"),
                Chip("elev1", Theme.Color.elev1, "cards"),
                Chip("elev2", Theme.Color.elev2, "controls · icon chips"),
                Chip("elev3", Theme.Color.elev3, "raised · idle fill"),
                Chip("label1", Theme.Color.label1, "primary text"),
                Chip("label2", Theme.Color.label2, "secondary text"),
                Chip("label3", Theme.Color.label3, "tertiary text"),
                Chip("separator", Theme.Color.separator, "hairlines"),
                Chip("idleTrack", Theme.Color.idleTrack, "unfilled progress")
            ])
        }
    }

    private var semanticSection: some View {
        Group1(title: "Semantic — reserved") {
            SwatchGrid(chips: [
                Chip("success", Theme.Color.success, "verified · complete"),
                Chip("danger", Theme.Color.danger, "failure · destructive"),
                Chip("warning", Theme.Color.warning, "caution")
            ])
        }
    }

    // MARK: - Metrics

    private var metricSection: some View {
        Group1(title: "Metrics — drawn at true size") {
            VStack(alignment: .leading, spacing: 16) {
                MetricRow("progressBar", Theme.Metric.progressBar, "4 pt, fully rounded") {
                    ProgressSpecimen(fraction: 0.63)
                }

                MetricRow("segmentBar", Theme.Metric.segmentBar, "7 pt, radius 3.5") {
                    VStack(spacing: 5) {
                        SegmentSpecimen(fraction: 1.0, fill: .success)
                        SegmentSpecimen(fraction: 0.78, fill: .active)
                        SegmentSpecimen(fraction: 0.22, fill: .idle)
                    }
                }

                MetricRow("rowIcon", Theme.Metric.rowIcon, "38 pt, radius 10") {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: Theme.Metric.rowIconRadius, style: .continuous)
                            .fill(Theme.Color.ember.opacity(0.16))
                            .frame(width: Theme.Metric.rowIcon, height: Theme.Metric.rowIcon)
                            .overlay {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Theme.Color.ember)
                            }
                        RoundedRectangle(cornerRadius: Theme.Metric.rowIconRadius, style: .continuous)
                            .fill(Theme.Color.elev2)
                            .frame(width: Theme.Metric.rowIcon, height: Theme.Metric.rowIcon)
                            .overlay {
                                Image(systemName: "clock")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Theme.Color.label2)
                            }
                        Spacer(minLength: 0)
                    }
                }

                MetricRow("cardRadius", Theme.Metric.cardRadius, "14 pt · gutter 16 pt") {
                    RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous)
                        .fill(Theme.Color.elev1)
                        .frame(height: 52)
                        .overlay(alignment: .leading) {
                            Text("card")
                                .font(Theme.Typo.mono)
                                .foregroundStyle(Theme.Color.label3)
                                .padding(.leading, 12)
                        }
                }

                MetricRow("widgetRadius", Theme.Metric.widgetRadius, "22 pt · hairline border") {
                    RoundedRectangle(cornerRadius: Theme.Metric.widgetRadius, style: .continuous)
                        .fill(Theme.Color.elev1)
                        .frame(height: 64)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Metric.widgetRadius, style: .continuous)
                                .strokeBorder(Theme.Color.separator, lineWidth: Theme.Metric.hairline)
                        }
                }

                MetricRow("hairline", Theme.Metric.hairline, "0.5 pt · inset 16 pt") {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("row above")
                            .font(Theme.Typo.rowSubtitle)
                            .foregroundStyle(Theme.Color.label2)
                            .padding(.vertical, Theme.Metric.rowVerticalPadding)
                        Rectangle()
                            .fill(Theme.Color.separator)
                            .frame(height: Theme.Metric.hairline)
                            .padding(.leading, Theme.Metric.separatorInset)
                        Text("row below · rowVerticalPadding 12 pt")
                            .font(Theme.Typo.rowSubtitle)
                            .foregroundStyle(Theme.Color.label2)
                            .padding(.vertical, Theme.Metric.rowVerticalPadding)
                    }
                }

                MetricRow("switchSize", Theme.Metric.switchSize.width, "51 × 31 pt · system default") {
                    HStack(spacing: 12) {
                        Toggle("", isOn: $switchOn)
                            .labelsHidden()
                            .tint(Theme.Color.success)
                        Text("\(Int(Theme.Metric.switchSize.width)) × \(Int(Theme.Metric.switchSize.height))")
                            .font(Theme.Typo.mono)
                            .foregroundStyle(Theme.Color.label3)
                        Spacer(minLength: 0)
                    }
                }

                MetricRow("scrubberTrack", Theme.Metric.scrubberTrack, "6 pt track · 13 pt knob") {
                    ScrubberSpecimen()
                }

                MetricRow("minHitTarget", Theme.Metric.minHitTarget, "44 × 44 pt minimum") {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.Color.ember, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: Theme.Metric.minHitTarget, height: Theme.Metric.minHitTarget)
                            .overlay {
                                Image(systemName: "hand.tap")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Theme.Color.ember)
                            }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Type

    private var typeSection: some View {
        Group1(title: "Type scale") {
            VStack(alignment: .leading, spacing: 14) {
                TypeRow("bigNumber", "52 · bold · tabular") {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("63")
                            .font(Theme.Typo.bigNumber)
                            .foregroundStyle(Theme.Color.label1)
                        Text("%")
                            .font(Theme.Typo.bigNumberUnit)
                            .foregroundStyle(Theme.Color.label2)
                    }
                }
                TypeRow("detailTitle", "19 · semibold") {
                    Text("ubuntu-24.04.1-desktop-amd64.iso")
                        .font(Theme.Typo.detailTitle)
                        .foregroundStyle(Theme.Color.label1)
                }
                TypeRow("rowTitle", "15 · semibold") {
                    Text("Blender-4.2-macOS-arm64.dmg")
                        .font(Theme.Typo.rowTitle)
                        .foregroundStyle(Theme.Color.label1)
                }
                TypeRow("rowSubtitle", "12.5 · regular · monospacedDigit") {
                    Text("48.2 MB/s · 3.6 of 5.7 GB · 44s left")
                        .font(Theme.Typo.rowSubtitle.monospacedDigit())
                        .foregroundStyle(Theme.Color.label2)
                }
                TypeRow("sectionLabel", "11 · semibold · tracking 0.6") {
                    Text("Parallel connections — 6 active")
                        .font(Theme.Typo.sectionLabel)
                        .tracking(Theme.Typo.sectionTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Color.label2)
                }
                TypeRow("statLabel / statValue", "10.5 · tertiary / 16 · semibold") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloaded")
                            .font(Theme.Typo.statLabel)
                            .tracking(Theme.Typo.statTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Color.label3)
                        Text("3.61 GB")
                            .font(Theme.Typo.statValue)
                            .foregroundStyle(Theme.Color.label1)
                    }
                }
                TypeRow("mono", "11 · monospaced") {
                    Text("releases.ubuntu.com · 3 mirrors")
                        .font(Theme.Typo.mono)
                        .foregroundStyle(Theme.Color.label3)
                }
                TypeRow("caption", "11.5 · regular") {
                    Text("3:42  ·  −37:18")
                        .font(Theme.Typo.caption.monospacedDigit())
                        .foregroundStyle(Theme.Color.label2)
                }
            }
        }
    }

    // MARK: - Formatters

    private var formatterSection: some View {
        Group1(title: "Formatters — mockup values") {
            VStack(spacing: 0) {
                ForEach(Array(Self.formatterRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.Color.separator)
                            .frame(height: Theme.Metric.hairline)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.call)
                            .font(Theme.Typo.mono)
                            .foregroundStyle(Theme.Color.label3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.result)
                            .font(Theme.Typo.statValue)
                            .foregroundStyle(row.result == Fmt.placeholder ? Theme.Color.label3 : Theme.Color.label1)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private struct FormatterRow {
        var call: String
        var result: String
    }

    private static let formatterRows: [FormatterRow] = [
        FormatterRow(call: "bytes(5_730_000_000)", result: Fmt.bytes(5_730_000_000)),
        FormatterRow(call: "bytes(3_610_000_000)", result: Fmt.bytes(3_610_000_000)),
        FormatterRow(call: "bytes(412_300_000)", result: Fmt.bytes(412_300_000)),
        FormatterRow(call: "bytes(1_400_000_000)", result: Fmt.bytes(1_400_000_000)),
        FormatterRow(call: "bytes(18_000_000_000)", result: Fmt.bytes(18_000_000_000)),
        FormatterRow(call: "bytes(512)", result: Fmt.bytes(512)),
        FormatterRow(call: "bytes(nil)", result: Fmt.bytes(nil)),
        FormatterRow(call: "bytesPair(3_610_000_000, of: 5_730_000_000)",
                     result: Fmt.bytesPair(3_610_000_000, of: 5_730_000_000)),
        FormatterRow(call: "bytesPair(3_900_000_000, of: 12_600_000_000)",
                     result: Fmt.bytesPair(3_900_000_000, of: 12_600_000_000)),
        FormatterRow(call: "bytesPair(412_300_000, of: 5_730_000_000)",
                     result: Fmt.bytesPair(412_300_000, of: 5_730_000_000)),
        FormatterRow(call: "bytesPair(3_610_000_000, of: nil)",
                     result: Fmt.bytesPair(3_610_000_000, of: nil)),
        FormatterRow(call: "speed(48_200_000)", result: Fmt.speed(48_200_000)),
        FormatterRow(call: "speed(12_400_000)", result: Fmt.speed(12_400_000)),
        FormatterRow(call: "speed(.infinity)", result: Fmt.speed(.infinity)),
        FormatterRow(call: "speed(.nan)", result: Fmt.speed(.nan)),
        FormatterRow(call: "eta(44)", result: Fmt.eta(44)),
        FormatterRow(call: "eta(102)", result: Fmt.eta(102)),
        FormatterRow(call: "eta(8_040)", result: Fmt.eta(8_040)),
        FormatterRow(call: "eta(nil)", result: Fmt.eta(nil)),
        FormatterRow(call: "remainingLong(44)", result: Fmt.remainingLong(44)),
        FormatterRow(call: "duration(222)", result: Fmt.duration(222)),
        FormatterRow(call: "duration(3_731)", result: Fmt.duration(3_731)),
        FormatterRow(call: "duration(.nan)", result: Fmt.duration(.nan)),
        FormatterRow(call: "remaining(2_238)", result: Fmt.remaining(2_238)),
        FormatterRow(call: "percent(0.63)", result: Fmt.percent(0.63)),
        FormatterRow(call: "percent(.nan)", result: Fmt.percent(.nan)),
        FormatterRow(call: "percent(4.2)", result: Fmt.percent(4.2)),
        FormatterRow(call: "percentValue(0.63)", result: "\(Fmt.percentValue(0.63))"),
        FormatterRow(call: "relative(now − 120 s)",
                     result: Fmt.relative(Date(timeIntervalSince1970: 0),
                                          now: Date(timeIntervalSince1970: 120))),
        FormatterRow(call: "relative(now − 2 days)",
                     result: Fmt.relative(Date(timeIntervalSince1970: 0),
                                          now: Date(timeIntervalSince1970: 2 * 86_400)))
    ]
}

// MARK: - Building blocks

/// A titled group rendered on an `elev1` card.
private struct Group1<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.Typo.sectionLabel)
                .tracking(Theme.Typo.sectionTracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Color.label2)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous)
                    .fill(Theme.Color.elev1)
            )
        }
    }
}

private struct Chip: Identifiable {
    var id: String { name }
    var name: String
    var color: Color
    var role: String

    init(_ name: String, _ color: Color, _ role: String) {
        self.name = name
        self.color = color
        self.role = role
    }
}

private struct SwatchGrid: View {
    var chips: [Chip]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(chips) { chip in
                SwatchChip(chip: chip)
            }
        }
    }
}

private struct SwatchChip: View {
    var chip: Chip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: Theme.Metric.rowIconRadius, style: .continuous)
                .fill(chip.color)
                .frame(height: 46)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metric.rowIconRadius, style: .continuous)
                        .strokeBorder(Theme.Color.separator, lineWidth: Theme.Metric.hairline)
                }
            Text(chip.name)
                .font(Theme.Typo.rowTitle)
                .foregroundStyle(Theme.Color.label1)
            Text(hexDescription(chip.color, scheme: .dark) + " / " + hexDescription(chip.color, scheme: .light))
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Color.label2)
            Text(chip.role)
                .font(Theme.Typo.statLabel)
                .foregroundStyle(Theme.Color.label3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chip.name), \(chip.role)")
    }
}

/// Resolves a (possibly dynamic) colour for one appearance and renders it as `#RRGGBB`,
/// with the alpha appended when the token is translucent.
private func hexDescription(_ color: Color, scheme: ColorScheme) -> String {
    let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
    let resolved = UIColor(color).resolvedColor(with: traits)

    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return Fmt.placeholder
    }

    let hex = String(
        format: "#%02X%02X%02X",
        Int((red * 255).rounded()),
        Int((green * 255).rounded()),
        Int((blue * 255).rounded())
    )
    guard alpha < 0.995 else { return hex }
    return hex + String(format: "·%.0f%%", alpha * 100)
}

private struct GradientStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Color.emberGradient)
                .frame(height: 26)
            Text("emberGradient · #FF8A4C → #FF6B2C · leading to trailing")
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Color.label3)
        }
    }
}

// MARK: - Metric specimens

private struct MetricRow<Content: View>: View {
    var name: String
    var value: CGFloat
    var note: String
    @ViewBuilder var content: Content

    init(_ name: String, _ value: CGFloat, _ note: String, @ViewBuilder content: () -> Content) {
        self.name = name
        self.value = value
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(Theme.Typo.rowTitle)
                    .foregroundStyle(Theme.Color.label1)
                Text(note)
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.Color.label3)
            }
            content
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(note)")
        .accessibilityValue("\(value) points")
    }
}

private struct ProgressSpecimen: View {
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.Color.idleTrack)
                Capsule(style: .continuous)
                    .fill(Theme.Color.emberGradient)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: Theme.Metric.progressBar)
        .accessibilityValue(Fmt.percent(fraction))
    }
}

private struct SegmentSpecimen: View {
    enum Fill { case active, success, idle }

    var fraction: Double
    var fill: Fill

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Metric.segmentRadius, style: .continuous)
                    .fill(Theme.Color.idleTrack)
                Group {
                    switch fill {
                    case .active:
                        RoundedRectangle(cornerRadius: Theme.Metric.segmentRadius, style: .continuous)
                            .fill(Theme.Color.emberGradient)
                    case .success:
                        RoundedRectangle(cornerRadius: Theme.Metric.segmentRadius, style: .continuous)
                            .fill(Theme.Color.success)
                    case .idle:
                        RoundedRectangle(cornerRadius: Theme.Metric.segmentRadius, style: .continuous)
                            .fill(Theme.Color.elev3)
                    }
                }
                .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: Theme.Metric.segmentBar)
        .accessibilityValue(Fmt.percent(fraction))
    }
}

private struct ScrubberSpecimen: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.Color.idleTrack)
                Capsule(style: .continuous)
                    .fill(Theme.Color.label3)
                    .frame(width: proxy.size.width * 0.23)
                Capsule(style: .continuous)
                    .fill(Theme.Color.label1)
                    .frame(width: proxy.size.width * 0.09)
                Circle()
                    .fill(Theme.Color.label1)
                    .frame(width: Theme.Metric.scrubberKnob, height: Theme.Metric.scrubberKnob)
                    .offset(x: proxy.size.width * 0.09 - Theme.Metric.scrubberKnob / 2)
            }
        }
        .frame(height: Theme.Metric.scrubberKnob)
    }
}

private struct TypeRow<Content: View>: View {
    var name: String
    var note: String
    @ViewBuilder var content: Content

    init(_ name: String, _ note: String, @ViewBuilder content: () -> Content) {
        self.name = name
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(Theme.Typo.statLabel)
                    .tracking(Theme.Typo.statTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Color.ember)
                Text(note)
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.Color.label3)
            }
            content
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

// MARK: - Previews

#Preview("Dark") {
    SwatchView().preferredColorScheme(.dark)
}

#Preview("Light") {
    SwatchView().preferredColorScheme(.light)
}
