import SwiftUI
import GoelCore

/// An empty or no-match state: an accent tile, a display title, a sentence and actions.
///
///     StudioEmptyState(symbol: "tray", title: "Nothing here yet",
///                      message: "Paste a link into the box above.") {
///         Button("Clear filters") { … }.buttonStyle(.studio(.primary))
///     }
struct StudioEmptyState<Actions: View>: View {
    var symbol: String
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: Studio.Space.ml) {
            Image(systemName: symbol)
                .font(StudioFonts.font(.ui, size: 26, weight: 600))
                .foregroundStyle(Studio.Palette.accent)
                .frame(width: 64, height: 64)
                .background(Studio.Palette.accentSoft, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: Studio.Space.xs) {
                Text(title)
                    .studioFont(.title2)
                    .foregroundStyle(Studio.Palette.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .studioFont(.body)
                        .foregroundStyle(Studio.Palette.ink2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 420)
            HStack(spacing: Studio.Space.s) { actions() }
        }
        .padding(Studio.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

extension StudioEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message, actions: { EmptyView() })
    }
}

/// A toast (`.toast`): a floating card with a tinted glyph tile, text, an optional action (Undo)
/// and a dismiss button. The host decides placement and timing (see `ToastQueue`).
struct StudioToastCard: View {
    var tone: StudioTone = .accent
    var symbol: String = "checkmark"
    let title: String
    var message: String?
    var actionTitle: String?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Studio.Space.m) {
            Image(systemName: symbol)
                .font(StudioFonts.font(.ui, size: 14, weight: 700))
                .foregroundStyle(tone.foreground)
                .frame(width: 32, height: 32)
                .background(tone.background, in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(2)
                if let message {
                    Text(message)
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction).buttonStyle(.studio(.soft, size: .small))
            }
            if let onDismiss {
                StudioIconButton("xmark", label: L10n.t("Dismiss"), size: .small, action: onDismiss)
            }
        }
        .padding(.leading, Studio.Space.ml)
        .padding([.vertical, .trailing], Studio.Space.m)
        .frame(width: 380)
        .studioSurface(.raised, radius: Studio.Radius.card, elevation: .floating)
    }
}

/// A sparkline or small area chart (`.spark`): an accent line with a soft fill, an optional dashed
/// upload line, optional grid lines and an end dot. Values are scaled to the tallest point (or
/// `maxValue`).
///
///     StudioSparkline(values: history.map(\.down), secondary: history.map(\.up), showsEndDot: true)
///         .frame(height: 60)
struct StudioSparkline: View {
    let values: [Double]
    var secondary: [Double]?
    var maxValue: Double?
    var showsFill = true
    var gridLines = 0
    var showsEndDot = false
    var color: Color = Studio.Palette.accent
    var secondaryColor: Color = Studio.Palette.upload
    var accessibilityLabel: String = L10n.t("Speed history")

    var body: some View {
        Canvas { context, size in
            let top = max(maxValue ?? 0, values.max() ?? 0, secondary?.max() ?? 0, 1e-9)
            if gridLines > 0 {
                for index in 1...gridLines {
                    let y = size.height * CGFloat(index) / CGFloat(gridLines + 1)
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(Studio.Palette.hairline), lineWidth: 1)
                }
            }
            let points = Self.points(values, in: size, top: top)
            if showsFill, let first = points.first, let last = points.last {
                var area = Path()
                area.move(to: CGPoint(x: first.x, y: size.height))
                points.forEach { area.addLine(to: $0) }
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(Studio.Palette.accentSoft))
            }
            if let secondary {
                let upPoints = Self.points(secondary, in: size, top: top)
                context.stroke(Self.line(upPoints), with: .color(secondaryColor),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            context.stroke(Self.line(points), with: .color(color),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            if showsEndDot, let last = points.last {
                let dot = Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7))
                context.fill(dot, with: .color(color))
                context.stroke(dot, with: .color(Studio.Palette.card), lineWidth: 2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(values.last.map { A11y.speed($0) } ?? "")
    }

    private static func points(_ values: [Double], in size: CGSize, top: Double) -> [CGPoint] {
        guard values.count > 1 else {
            return values.map { CGPoint(x: size.width, y: size.height * (1 - CGFloat($0 / top))) }
        }
        let inset: CGFloat = 1
        let usable = size.height - inset * 2
        return values.enumerated().map { index, value in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: inset + usable * (1 - CGFloat(max(0, value) / top)))
        }
    }

    private static func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }
}

/// Alias for clarity where the chart is the main content rather than an inline sparkline.
typealias StudioAreaChart = StudioSparkline
