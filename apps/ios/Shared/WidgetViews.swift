import ActivityKit
import SwiftUI
import WidgetKit
#if canImport(AppIntents)
import AppIntents
#endif

/// Every pixel the widget extension draws, and the only place those pixels are defined.
///
/// This file is compiled into **both** targets. The extension renders these views for real; the
/// in-app Widget Gallery (`Features/Debug/WidgetGalleryView.swift`) renders the *same* views at
/// the exact accessory dimensions, because `simctl` cannot lock the simulator and a Lock Screen
/// widget can therefore never be screenshotted directly. If the two ever diverged the gallery
/// would stop proving anything, so nothing here may live in the app target.
///
/// Consequences of that dual membership, both easy to trip over:
///
/// * **`Theme` and `Fmt` do not exist here.** They are app-only. Colours come from
///   ``SharedTheme``; the three or four number formats §6.5 needs are re-implemented in
///   ``WidgetFormat`` below, deliberately duplicated rather than shared, with the algorithm kept
///   byte-identical to `Fmt` so the Live Activity and the queue row can never disagree.
/// * **`Download`, `DownloadStore`, `AppModel` do not exist here either.** The extension sees a
///   `SharedSnapshot` and a `DownloadActivityAttributes.ContentState`. That is all.

// MARK: - Palette

/// The handful of colour values the mockup uses that are not in ``SharedTheme``.
///
/// `Theme.Color.idleTrack` is app-only, so the extension carries its own copy of the one track
/// colour it needs. Values are lifted verbatim from `visual.html`.
public enum WidgetPalette {

    /// Unfilled progress track — `rgba(120,120,128,.32)` dark · `.20` light.
    public static let idleTrack = Color(uiColor: UIColor { traits in
        UIColor(
            red: 120 / 255,
            green: 120 / 255,
            blue: 128 / 255,
            alpha: traits.userInterfaceStyle == .dark ? 0.32 : 0.20
        )
    })

    /// The degraded progress fill — `rgba(235,235,245,.34)`, the mockup's "honest degradation"
    /// grey. A stale bar must not read as ember, because ember means "bytes are moving".
    public static let staleFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.34)
            : UIColor(white: 0, alpha: 0.26)
    })

    /// Live Activity and Home Screen widget card fill — `rgba(28,28,30,.84)`.
    public static let cardFill = SharedTheme.elev1.opacity(0.84)

    /// The `.5 pt` hairline around a card — `rgba(255,255,255,.10)`.
    public static let cardStroke = Color.white.opacity(0.10)

    /// Live Activity button chrome — `rgba(120,120,128,.26)`.
    public static let controlFill = Color(uiColor: UIColor(
        red: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.26
    ))

    /// Glyph chip ground — `rgba(255,107,44,.20)`.
    public static let glyphChip = SharedTheme.ember.opacity(0.20)

    /// The 20 %-white ring track used inside the Dynamic Island, which is always black.
    public static let ringTrack = Color.white.opacity(0.20)
}

// MARK: - Formatting

/// The number formats the extension needs.
///
/// **Why this is a duplicate.** `Fmt` lives in `Goel/DesignSystem/Formatters.swift`, which is a
/// member of the app target only — the widget extension cannot see it, and moving it into
/// `Shared/` was not this task's to do. Rather than approximate, the scaling algorithm below is
/// a transcription of `Fmt`'s: base-10 units, two decimals under a mantissa of 10 and one above,
/// trailing zeros trimmed, `String(format:)` so the decimal separator never changes with locale.
/// `5.73 GB`, `3.61 GB`, `48.2 MB/s`, `63%` come out byte-identical on both sides of the seam.
///
/// If `Fmt` ever moves to `Shared/`, delete this and forward to it.
public enum WidgetFormat {

    /// Em dash (U+2014) — the mockup's "unknown value" placeholder.
    public static let placeholder = "—"

    private static let unitNames = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    private static let rateUnitNames = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// `5.73 GB`, `412.3 MB`, `512 bytes`.
    public static func bytes(_ n: Int64) -> String {
        let scaled = scale(Double(max(n, 0)), maxDecimals: 2)
        return "\(mantissa(scaled)) \(unitNames[scaled.unit])"
    }

    /// `3.61 of 5.73 GB`, `412.3 MB of 5.7 GB`, or just `3.6 GB` when the total is unknown.
    public static func bytesPair(_ received: Int64, of total: Int64?) -> String {
        let got = scale(Double(max(received, 0)), maxDecimals: 2)
        guard let total, total > 0 else {
            return "\(mantissa(got)) \(unitNames[got.unit])"
        }
        let all = scale(Double(total), maxDecimals: 2)
        if got.unit == all.unit {
            return "\(mantissa(got)) of \(mantissa(all)) \(unitNames[all.unit])"
        }
        return "\(mantissa(got)) \(unitNames[got.unit]) of \(mantissa(all)) \(unitNames[all.unit])"
    }

    /// `48.2 MB/s`. Non-finite or negative input renders as `—`.
    public static func speed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec.isFinite, bytesPerSec >= 0 else { return placeholder }
        let scaled = scale(bytesPerSec, maxDecimals: 1)
        return "\(mantissa(scaled)) \(rateUnitNames[scaled.unit])/s"
    }

    /// Widget-grade ETA: `44 s`, `5 m`, `2 h`. Deliberately coarse — a widget refreshes tens of
    /// times a day, so a minute-accurate countdown there would be theatre.
    public static func etaCompact(_ seconds: TimeInterval?) -> String? {
        guard let total = wholeSeconds(seconds) else { return nil }
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) m" }
        return "\(total / 3600) h"
    }

    /// Expanded-Island ETA, long form: `44 s remaining`, `1 m 42 s remaining`.
    public static func remainingLong(_ seconds: TimeInterval?) -> String? {
        guard let total = wholeSeconds(seconds) else { return nil }
        if total < 60 { return "\(total) s remaining" }
        if total < 3600 { return "\(total / 60) m \(total % 60) s remaining" }
        return "\(total / 3600) h \((total % 3600) / 60) m remaining"
    }

    /// `63%`. Clamped to `0...1`; non-finite input renders as `0%`.
    public static func percent(_ fraction: Double) -> String { "\(percentValue(fraction))%" }

    /// `63`. Clamped to `0...100`; non-finite input returns `0`.
    public static func percentValue(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    // MARK: Private

    private struct Scaled {
        var mantissa: Double
        var unit: Int
        var maxDecimals: Int
    }

    private static func scale(_ value: Double, maxDecimals: Int) -> Scaled {
        guard value.isFinite, value > 0 else {
            return Scaled(mantissa: 0, unit: 0, maxDecimals: maxDecimals)
        }
        var m = value
        var unit = 0
        while m >= 1000, unit < unitNames.count - 1 {
            m /= 1000
            unit += 1
        }
        var scaled = Scaled(mantissa: m, unit: unit, maxDecimals: maxDecimals)
        if rounded(scaled) >= 1000, unit < unitNames.count - 1 {
            scaled.mantissa = m / 1000
            scaled.unit = unit + 1
        }
        return scaled
    }

    private static func decimals(for scaled: Scaled) -> Int {
        guard scaled.unit > 0 else { return 0 }
        return scaled.mantissa < 10 ? scaled.maxDecimals : min(scaled.maxDecimals, 1)
    }

    private static func rounded(_ scaled: Scaled) -> Double {
        let factor = pow(10.0, Double(decimals(for: scaled)))
        return (scaled.mantissa * factor).rounded() / factor
    }

    private static func mantissa(_ scaled: Scaled) -> String {
        var text = String(format: "%.\(decimals(for: scaled))f", rounded(scaled))
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func wholeSeconds(_ seconds: TimeInterval?) -> Int? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 100 * 365 * 24 * 3600 else { return nil }
        return max(1, Int(seconds.rounded()))
    }
}

// MARK: - Glyphs

/// `kindToken` → SF Symbol, without importing `Download.Kind`.
///
/// The tokens are `Download.Kind.rawValue` (`http`, `https`, `ftp`, `sftp`, `hls`) plus the
/// synthetic `"aggregate"` the aggregate Live Activity uses. HTTP(S) maps to the download-tray
/// glyph rather than a padlock because that is what `visual.html` draws for the ubuntu row on
/// every surface — the padlock is the queue row's *status* affordance, not the transfer's.
public enum WidgetGlyph {

    public static let aggregateToken = "aggregate"

    public static func symbol(for token: String) -> String {
        switch token {
        case "ftp": "folder.fill"
        case "sftp": "lock.shield.fill"
        case "hls": "play.rectangle.fill"
        default: "square.and.arrow.down"
        }
    }

    /// The bare arrow used where there is no room for a chip — compact Island leading, the
    /// `Goel°` widget header, the inline accessory.
    public static let arrow = "arrow.down"

    /// The mockup tints the `sftp` channel cyan (`--ios-cyan`) and everything else ember.
    public static func tint(for token: String) -> Color {
        switch token {
        case "sftp", "ftp": SharedTheme.instrument
        default: SharedTheme.ember
        }
    }
}

// MARK: - Primitives

/// The 30 pt rounded chip that carries the kind glyph. `.la-top .la-ic` in `visual.html`.
public struct WidgetGlyphChip: View {
    public var systemName: String
    public var tint: Color
    public var edge: CGFloat
    public var isMuted: Bool

    public init(systemName: String, tint: Color = SharedTheme.ember, edge: CGFloat = 30, isMuted: Bool = false) {
        self.systemName = systemName
        self.tint = tint
        self.edge = edge
        self.isMuted = isMuted
    }

    public var body: some View {
        // Degraded, the chip keeps its tinted ground and loses only the glyph's colour — the
        // mockup's stale card is still recognisably a Goel transfer, just not a live one.
        let colour = isMuted ? SharedTheme.label3 : tint
        RoundedRectangle(cornerRadius: edge * 0.27, style: .continuous)
            .fill(tint.opacity(isMuted ? 0.14 : 0.20))
            .frame(width: edge, height: edge)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: edge * 0.55, weight: .medium))
                    .foregroundStyle(colour)
            }
            .accessibilityHidden(true)
    }
}

/// The 4 pt fully-rounded progress bar — `.track` / `.track i` in `visual.html`.
public struct WidgetProgressBar: View {
    public var fraction: Double
    public var fill: AnyShapeStyle
    public var height: CGFloat

    public init(fraction: Double, fill: AnyShapeStyle = AnyShapeStyle(SharedTheme.emberGradient), height: CGFloat = SharedTheme.progressBar) {
        self.fraction = fraction
        self.fill = fill
        self.height = height
    }

    /// The neutral, desaturated bar the stale branch draws. §6.5: while the app is suspended the
    /// number behind this bar is not one we can stand behind, so it must not look live.
    public static func stale(fraction: Double) -> WidgetProgressBar {
        WidgetProgressBar(fraction: fraction, fill: AnyShapeStyle(WidgetPalette.staleFill))
    }

    public var body: some View {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.idleTrack)
                Capsule().fill(fill).frame(width: clamped * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The circular progress ring the Dynamic Island shows in compact and minimal.
/// Ember on a 20 %-white track, rotated −90° so zero sits at twelve o'clock, rounded cap.
public struct WidgetProgressRing: View {
    public var fraction: Double
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    public var tint: Color
    public var track: Color

    public init(
        fraction: Double,
        diameter: CGFloat = 21,
        lineWidth: CGFloat = 3,
        tint: Color = SharedTheme.ember,
        track: Color = WidgetPalette.ringTrack
    ) {
        self.fraction = fraction
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.tint = tint
        self.track = track
    }

    public var body: some View {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                // A hair of arc at 0 % so the ring never reads as "nothing is happening".
                .trim(from: 0, to: max(0.02, clamped))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(WidgetFormat.percentValue(clamped)) percent")
    }
}

/// The `FASTEST` widget's mini sparkline.
///
/// With fewer than two samples it draws a flat line at the current level rather than inventing a
/// shape: `SharedSnapshot` carries no time series, and a widget that fabricates history is
/// exactly the sort of confident lie §6.5 rules out.
public struct WidgetSparkline: View {
    public var samples: [Double]
    public var tint: Color

    public init(samples: [Double], tint: Color = SharedTheme.ember) {
        self.samples = samples.filter(\.isFinite)
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(tint).frame(width: 5.2, height: 5.2).position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let inset: CGFloat = 3
        let top = inset, bottom = max(inset, size.height - inset)
        guard samples.count > 1 else {
            let y = (top + bottom) / 2
            return [CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)]
        }
        let lo = samples.min() ?? 0
        let hi = samples.max() ?? 1
        let span = hi - lo
        let step = size.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { i, v in
            let unit = span > 0 ? (v - lo) / span : 0.5
            return CGPoint(x: CGFloat(i) * step, y: bottom - CGFloat(unit) * (bottom - top))
        }
    }
}

/// The card ground shared by the Live Activity and the Home Screen widgets:
/// `elev1` at 84 %, radius 22, `.5 pt` hairline. Used as a `containerBackground` in the
/// extension (where it fills the widget's real bounds, so the stroke lands on the true edge)
/// and as a plain background in the gallery.
public struct WidgetSurface: View {
    public var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = SharedTheme.widgetRadius) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        ZStack {
            WidgetPalette.cardFill
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(WidgetPalette.cardStroke, lineWidth: 0.5)
        }
    }
}

// MARK: - Live Activity buttons

/// Pause / Resume and Cancel, as drawn in `visual.html` frames 5 and 6.
///
/// App Intents, and `Shared/DownloadIntents.swift` (T15) has not been written yet — inventing the
/// intent types here would mean the next agent has to delete them. The layout, the metrics and
/// the red Cancel are final; only the action is a stub.
public struct LiveActivityActionButtons: View {
    public var downloadID: String
    public var isPaused: Bool
    public var minHeight: CGFloat

    public init(downloadID: String, isPaused: Bool, minHeight: CGFloat = 44) {
        self.downloadID = downloadID
        self.isPaused = isPaused
        self.minHeight = minHeight
    }

    public var body: some View {
        HStack(spacing: 8) {
            button(title: isPaused ? "Resume" : "Pause", tint: SharedTheme.label1)
            button(title: "Cancel", tint: SharedTheme.danger)
        }
    }

    @ViewBuilder
    private func button(title: String, tint: Color) -> some View {
        let label = Text(title)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(WidgetPalette.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        #if canImport(AppIntents)
        // T15: backed by App Intents, every one of which sets `openAppWhenRun = false` — the tap
        // is handled out of process and the app is never opened. See Shared/DownloadIntents.swift.
        DownloadIntentButton(
            action: title == "Cancel" ? .cancel : (isPaused ? .resume : .pause),
            downloadID: downloadID,
            accessibilityLabel: title
        ) { label }
        #else
        label
        #endif
    }
}

// MARK: - Live Activity — lock screen / banner

/// The Lock Screen and banner presentation. `visual.html` frame 5, `.la`.
///
/// Two layouts, one view. The live one carries a percentage, an ETA and both buttons; the stale
/// one carries neither a percentage nor an ETA, because during a background `URLSession` the app
/// is not running and any precise number would be a lie. See ``staleSubtitle(for:)``.
public struct LiveActivityLockScreenView: View {
    public var state: DownloadActivityAttributes.ContentState
    public var downloadID: String
    public var kindToken: String
    public var isStale: Bool

    public init(
        state: DownloadActivityAttributes.ContentState,
        downloadID: String,
        kindToken: String,
        isStale: Bool
    ) {
        self.state = state
        self.downloadID = downloadID
        self.kindToken = kindToken
        self.isStale = isStale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            LiveActivityHeader(state: state, kindToken: kindToken, isStale: isStale, showsETA: false)

            if isStale {
                WidgetProgressBar.stale(fraction: state.fraction)
            } else {
                WidgetProgressBar(fraction: state.fraction)
            }

            // The mockup drops the controls in the degraded state: with the numbers untrustworthy
            // the card falls back to pure information, and the queue screen owns the actions.
            if !isStale {
                LiveActivityActionButtons(downloadID: downloadID, isPaused: state.isPaused, minHeight: 44)
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
    }
}

/// The chip + name + numbers + percent row shared by the Lock Screen card and the expanded
/// Dynamic Island. `showsETA` picks between the two subtitles the mockup draws: the Lock Screen
/// shows `3.61 of 5.73 GB · 48.2 MB/s`, the Island shows `48.2 MB/s · 44 s remaining`.
public struct LiveActivityHeader: View {
    public var state: DownloadActivityAttributes.ContentState
    public var kindToken: String
    public var isStale: Bool
    public var showsETA: Bool

    public init(
        state: DownloadActivityAttributes.ContentState,
        kindToken: String,
        isStale: Bool,
        showsETA: Bool
    ) {
        self.state = state
        self.kindToken = kindToken
        self.isStale = isStale
        self.showsETA = showsETA
    }

    public var body: some View {
        HStack(spacing: 10) {
            WidgetGlyphChip(
                systemName: WidgetGlyph.symbol(for: kindToken),
                tint: WidgetGlyph.tint(for: kindToken),
                edge: 30,
                isMuted: isStale
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(SharedTheme.label1)

                subtitle
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(isStale ? SharedTheme.label3 : SharedTheme.label2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(isStale ? WidgetFormat.placeholder : WidgetFormat.percent(state.fraction))
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(isStale ? SharedTheme.label3 : SharedTheme.label1)
                .accessibilityLabel("Progress")
                .accessibilityValue(isStale ? "Unknown, last update \(state.receivedBytes) bytes" : "\(WidgetFormat.percentValue(state.fraction)) percent")
        }
    }

    private var subtitle: Text {
        if isStale { return LiveActivityLockScreenView.staleSubtitle(for: state) }
        if state.isPaused {
            return Text("Paused · \(WidgetFormat.bytesPair(state.receivedBytes, of: state.totalBytes))")
        }
        if showsETA {
            let speed = WidgetFormat.speed(state.speed)
            if let eta = WidgetFormat.remainingLong(state.eta) {
                return Text("\(speed) · \(eta)")
            }
            return Text(speed)
        }
        return Text("\(WidgetFormat.bytesPair(state.receivedBytes, of: state.totalBytes)) · \(WidgetFormat.speed(state.speed))")
    }
}

extension LiveActivityLockScreenView {
    /// `3.61 GB downloaded · updated 2 min ago`.
    ///
    /// The relative half is a live `Text(_:style:)`, not a string we baked at publish time — a
    /// stale activity is by definition one nobody is updating, so the only honest way for the
    /// age to keep counting up is to let the system render it from `updatedAt`.
    public static func staleSubtitle(for state: DownloadActivityAttributes.ContentState) -> Text {
        Text("\(WidgetFormat.bytes(state.receivedBytes)) downloaded · updated ")
            + Text(state.updatedAt, style: .relative)
            + Text(" ago")
    }
}

// MARK: - Live Activity — Dynamic Island expanded

/// The four expanded regions, assembled into one view so the gallery can draw the layout that
/// `simctl` cannot trigger. The extension uses ``leading``/``trailing``/``center``/``bottom``
/// individually inside `DynamicIslandExpandedRegion`.
public struct IslandExpandedView: View {
    public var state: DownloadActivityAttributes.ContentState
    public var downloadID: String
    public var kindToken: String
    public var isStale: Bool

    public init(
        state: DownloadActivityAttributes.ContentState,
        downloadID: String,
        kindToken: String,
        isStale: Bool
    ) {
        self.state = state
        self.downloadID = downloadID
        self.kindToken = kindToken
        self.isStale = isStale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                IslandExpanded.leading(kindToken: kindToken, isStale: isStale)
                IslandExpanded.center(state: state, isStale: isStale)
                IslandExpanded.trailing(state: state, isStale: isStale)
            }
            IslandExpanded.bottom(state: state, downloadID: downloadID, isStale: isStale)
        }
    }
}

/// The region builders, so `LiveActivityWidget.swift` and the gallery draw the same thing.
///
/// `@MainActor` because everything they return is a `View`, and `View` is main-actor isolated.
@MainActor
public enum IslandExpanded {

    public static func leading(kindToken: String, isStale: Bool) -> some View {
        WidgetGlyphChip(
            systemName: WidgetGlyph.symbol(for: kindToken),
            tint: WidgetGlyph.tint(for: kindToken),
            edge: 30,
            isMuted: isStale
        )
    }

    public static func trailing(state: DownloadActivityAttributes.ContentState, isStale: Bool) -> some View {
        Text(isStale ? WidgetFormat.placeholder : WidgetFormat.percent(state.fraction))
            .font(.system(size: 20, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(isStale ? SharedTheme.label3 : SharedTheme.label1)
            .accessibilityLabel("Progress")
            .accessibilityValue(isStale ? "Unknown" : "\(WidgetFormat.percentValue(state.fraction)) percent")
    }

    @ViewBuilder
    public static func center(state: DownloadActivityAttributes.ContentState, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(SharedTheme.label1)

            centerSubtitle(state: state, isStale: isStale)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(isStale ? SharedTheme.label3 : SharedTheme.label2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    public static func bottom(
        state: DownloadActivityAttributes.ContentState,
        downloadID: String,
        isStale: Bool
    ) -> some View {
        VStack(spacing: 11) {
            if isStale {
                WidgetProgressBar.stale(fraction: state.fraction)
            } else {
                WidgetProgressBar(fraction: state.fraction)
                LiveActivityActionButtons(downloadID: downloadID, isPaused: state.isPaused, minHeight: 36)
            }
        }
    }

    private static func centerSubtitle(
        state: DownloadActivityAttributes.ContentState,
        isStale: Bool
    ) -> Text {
        if isStale { return LiveActivityLockScreenView.staleSubtitle(for: state) }
        if state.isPaused {
            return Text("Paused · \(WidgetFormat.bytesPair(state.receivedBytes, of: state.totalBytes))")
        }
        let speed = WidgetFormat.speed(state.speed)
        if let eta = WidgetFormat.remainingLong(state.eta) {
            return Text("\(speed) · \(eta)")
        }
        return Text(speed)
    }
}

// MARK: - Accessory widgets

/// Everything an accessory widget needs, derived once from a ``SharedSnapshot``.
///
/// Aggregate only. §6.5: the widget is the *ambient* surface and refreshes on a budget of tens
/// per day — it must never be close enough to a per-second number to visibly disagree with the
/// Live Activity.
public struct WidgetSummary: Equatable, Sendable {
    public var activeCount: Int
    public var fraction: Double
    public var remainingBytes: Int64
    public var totalSpeed: Double
    public var topName: String?
    public var topKindToken: String
    public var isIdle: Bool

    public init(snapshot: SharedSnapshot) {
        activeCount = snapshot.activeCount
        fraction = snapshot.aggregateFraction
        remainingBytes = snapshot.totalRemainingBytes
        // Full-queue speed, to match the full-queue `remainingBytes` numerator. Summing only the
        // top-3 rows' speeds here dropped the excluded (least-complete, often fastest) downloads
        // from the denominator and inflated the ETA whenever more than three ran at once.
        totalSpeed = snapshot.totalSpeed
        topName = snapshot.top.first?.filename
        topKindToken = snapshot.top.first?.kindToken ?? WidgetGlyph.aggregateToken
        isIdle = snapshot.activeCount == 0 && snapshot.top.isEmpty
    }

    /// Seconds left across the whole queue, or `nil` when nothing is moving. Rendered coarsely
    /// (`44 s`, `5 m`, `2 h`) because the widget's refresh cadence cannot support more.
    public var eta: TimeInterval? {
        guard totalSpeed > 0, remainingBytes > 0 else { return nil }
        let seconds = Double(remainingBytes) / totalSpeed
        return seconds.isFinite ? seconds : nil
    }

    /// `63% · 2.1 GB left · 44 s`.
    public var aggregateLine: String {
        var parts = [WidgetFormat.percent(fraction), "\(WidgetFormat.bytes(remainingBytes)) left"]
        if let eta = WidgetFormat.etaCompact(eta) { parts.append(eta) }
        return parts.joined(separator: " · ")
    }

    /// `4 active · 21.4 GB`.
    public var inlineLine: String {
        isIdle ? "Idle" : "\(activeCount) active · \(WidgetFormat.bytes(remainingBytes))"
    }
}

/// `.accessoryCircular` — the aggregate percent as a ring. `visual.html` frame 5, left accessory.
public struct AccessoryCircularView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    public var summary: WidgetSummary

    public init(summary: WidgetSummary) { self.summary = summary }

    public var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Gauge(value: summary.fraction.isFinite ? min(max(summary.fraction, 0), 1) : 0) {
                Image(systemName: WidgetGlyph.arrow)
            } currentValueLabel: {
                Text("\(WidgetFormat.percentValue(summary.fraction))")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            // The Lock Screen renders accessories in a vibrant monochrome mode; a hardcoded
            // ember there is either ignored or muddy, so it is only applied in full colour.
            .tint(renderingMode == .fullColor ? SharedTheme.ember : nil)
        }
        .widgetAccentable()
        .accessibilityLabel("Downloads")
        .accessibilityValue("\(WidgetFormat.percentValue(summary.fraction)) percent complete")
    }
}

/// `.accessoryCircular`, second variant — `4 / ACTIVE`. `visual.html` frame 5, right accessory.
public struct AccessoryActiveCountView: View {
    public var summary: WidgetSummary

    public init(summary: WidgetSummary) { self.summary = summary }

    public var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -1) {
                Text("\(summary.activeCount)")
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                Text("ACTIVE")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
            }
            .minimumScaleFactor(0.6)
        }
        .widgetAccentable()
        .accessibilityLabel("Active downloads")
        .accessibilityValue("\(summary.activeCount)")
    }
}

/// `.accessoryRectangular` — `DOWNLOADING`, the top filename, and the aggregate line.
public struct AccessoryRectangularView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    public var summary: WidgetSummary

    public init(summary: WidgetSummary) { self.summary = summary }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(summary.isIdle ? "GOEL°" : "DOWNLOADING")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                // Ember only in full colour. On the Lock Screen the mode is vibrant, the tint is
                // dropped, and the mockup draws this label monochrome for exactly that reason.
                .foregroundStyle(renderingMode == .fullColor ? SharedTheme.ember : Color.secondary)
                .widgetAccentable()

            Text(summary.topName ?? "Nothing downloading")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(summary.isIdle ? "Queue empty" : summary.aggregateLine)
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// `.accessoryInline` — one line beside the clock: `↓ 4 active · 21.4 GB`.
public struct AccessoryInlineView: View {
    public var summary: WidgetSummary

    public init(summary: WidgetSummary) { self.summary = summary }

    public var body: some View {
        // Inline accessories flatten to one line of system-styled text plus one symbol; any font
        // or colour set here is dropped, which is exactly why nothing is set.
        Label {
            Text(summary.inlineLine)
        } icon: {
            Image(systemName: WidgetGlyph.arrow)
        }
        .accessibilityLabel("Downloads: \(summary.inlineLine)")
    }
}

// MARK: - Home Screen widgets

/// Small — `Goel°`, the active count, `active · 21.4 GB left`, aggregate bar.
/// `visual.html` frame 7, left widget.
public struct HomeSummaryView: View {
    public var summary: WidgetSummary

    public init(summary: WidgetSummary) { self.summary = summary }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Goel°", systemImage: WidgetGlyph.arrow)
            Spacer(minLength: 8)
            Text("\(summary.activeCount)")
                .font(.system(size: 34, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(SharedTheme.label1)
            Text(summary.isIdle ? "nothing queued" : "active · \(WidgetFormat.bytes(summary.remainingBytes)) left")
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(SharedTheme.label2)
                .padding(.top, 3)
            WidgetProgressBar(fraction: summary.fraction)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Goel downloads")
        .accessibilityValue("\(summary.activeCount) active, \(WidgetFormat.bytes(summary.remainingBytes)) left, \(WidgetFormat.percentValue(summary.fraction)) percent")
    }
}

/// Small, second variant — `FASTEST`: the quickest transfer's rate plus a mini sparkline.
/// `visual.html` frame 7, right widget.
public struct HomeFastestView: View {
    public var speed: Double
    public var filename: String?
    public var history: [Double]

    public init(speed: Double, filename: String?, history: [Double]) {
        self.speed = speed
        self.filename = filename
        self.history = history
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Fastest", systemImage: nil)
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(mantissaText)
                    .font(.system(size: 27, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(SharedTheme.label1)
                Text(unitText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SharedTheme.label2)
            }
            Text(filename ?? "Nothing downloading")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(SharedTheme.label2)
                .padding(.top, 3)
            Spacer(minLength: 6)
            WidgetSparkline(samples: history.isEmpty ? [speed] : history)
                .frame(height: 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fastest download")
        .accessibilityValue("\(WidgetFormat.speed(speed))\(filename.map { ", \($0)" } ?? "")")
    }

    /// `48.2 MB/s` split so the unit can take its own, smaller type — the mockup's treatment.
    private var split: (String, String) {
        let text = WidgetFormat.speed(speed)
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[text.startIndex..<space]), String(text[text.index(after: space)...]))
    }

    private var mantissaText: String { split.0 }
    private var unitText: String { split.1 }
}

/// Medium — `QUEUE`, up to three rows of name + percent, each with its own 4 pt bar.
/// `visual.html` frame 7, bottom widget. The `sftp` row is cyan, matching the mockup.
public struct HomeQueueView: View {
    public var items: [SharedSnapshot.Item]
    public var deepLinksEnabled: Bool

    public init(items: [SharedSnapshot.Item], deepLinksEnabled: Bool = true) {
        self.items = items
        self.deepLinksEnabled = deepLinksEnabled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "Queue", systemImage: nil)

            if items.isEmpty {
                Spacer(minLength: 0)
                Text("Queue empty")
                    .font(.system(size: 13))
                    .foregroundStyle(SharedTheme.label2)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 9) {
                    ForEach(items) { item in
                        row(for: item)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
    }

    @ViewBuilder
    private func row(for item: SharedSnapshot.Item) -> some View {
        let body = VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(item.filename)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(SharedTheme.label1)
                Spacer(minLength: 4)
                Text(WidgetFormat.percent(item.fraction))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(SharedTheme.label2)
            }
            WidgetProgressBar(
                fraction: item.fraction,
                fill: item.isPaused
                    ? AnyShapeStyle(WidgetPalette.staleFill)
                    : AnyShapeStyle(WidgetGlyph.tint(for: item.kindToken))
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.filename)
        .accessibilityValue("\(WidgetFormat.percentValue(item.fraction)) percent")

        // `AppModel.handle(url:)` already routes `goel://download/<id>` to the detail screen.
        if deepLinksEnabled, let url = GoelWidgetLink.download(id: item.id) {
            Link(destination: url) { body }
        } else {
            body
        }
    }
}

/// The uppercase widget header — `.w-h` in `visual.html`.
public struct WidgetHeader: View {
    public var title: String
    public var systemImage: String?

    public init(title: String, systemImage: String?) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SharedTheme.ember)
            }
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.55)
                .foregroundStyle(SharedTheme.label2)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Deep links

/// `goel://…` builders. The scheme is handled by `AppModel.handle(url:)`.
public enum GoelWidgetLink {
    public static func download(id: String) -> URL? {
        URL(string: "\(GoelIdentifiers.urlScheme)://download/\(id)")
    }

    /// The queue itself — used when there is no single row worth pointing at.
    public static var queue: URL? {
        URL(string: "\(GoelIdentifiers.urlScheme)://download")
    }
}

// MARK: - Preview data

/// Plausible, self-consistent data for `placeholder`, `snapshot`, and the Widget Gallery.
///
/// **This is the only place mockup numbers appear.** `visual.html` frame 5 shows the Lock Screen
/// at `63% · 2.1 GB left · 44 s`, frame 7 shows the Home Screen at `4 active · 21.4 GB left` and
/// 47 %; the two frames were drawn against different fixture queues and do not reconcile. Real
/// widgets compute everything from `SharedSnapshot`, so the discrepancy is confined to previews —
/// each surface previews with the fixture its own frame was drawn from, which is what makes the
/// gallery comparable to the mockup at all.
public enum WidgetSample {

    /// Frame 5's queue: one visible transfer, `2.1 GB` left at 63 %, four active in total.
    /// `2.1 GB / 48.2 MB/s` is 44 s, so the accessory ETA lands exactly on the mockup's.
    public static var lockScreen: SharedSnapshot {
        SharedSnapshot(
            activeCount: 4,
            totalRemainingBytes: 2_100_000_000,
            aggregateFraction: 0.63,
            updatedAt: Date(),
            top: [
                SharedSnapshot.Item(
                    id: "11111111-1111-1111-1111-111111111111",
                    filename: "ubuntu-24.04.1-desktop-amd64.iso",
                    fraction: 0.63,
                    speed: 48_200_000,
                    kindToken: "https",
                    isPaused: false
                )
            ]
        )
    }

    /// Frame 7's queue: four active, `21.4 GB` left at 47 %, three visible rows.
    public static var homeScreen: SharedSnapshot {
        SharedSnapshot(
            activeCount: 4,
            totalRemainingBytes: 21_400_000_000,
            aggregateFraction: 0.47,
            updatedAt: Date(),
            top: [
                SharedSnapshot.Item(
                    id: "11111111-1111-1111-1111-111111111111",
                    filename: "ubuntu-24.04.1-desktop-amd64.iso",
                    fraction: 0.63,
                    speed: 48_200_000,
                    kindToken: "https",
                    isPaused: false
                ),
                SharedSnapshot.Item(
                    id: "22222222-2222-2222-2222-222222222222",
                    filename: "nas-backup-2026-07-14.tar.zst",
                    fraction: 0.31,
                    speed: 12_400_000,
                    kindToken: "sftp",
                    isPaused: false
                ),
                SharedSnapshot.Item(
                    id: "33333333-3333-3333-3333-333333333333",
                    filename: "keynote-2026-4k-hdr.mp4",
                    fraction: 0.23,
                    speed: 9_800_000,
                    kindToken: "https",
                    isPaused: false
                )
            ]
        )
    }

    /// The sparkline in `visual.html` frame 7, as byte rates. Previews only — the live widget
    /// has no time series to draw and says so by flattening. See ``WidgetSparkline``.
    public static let speedHistory: [Double] = [
        31_000_000, 36_000_000, 33_000_000, 43_000_000,
        39_000_000, 47_000_000, 44_000_000, 48_200_000
    ]

    /// Computed, not stored: `DownloadActivityAttributes` is not `Sendable` (ActivityKit does not
    /// require it to be), so a `static let` would be a non-concurrency-safe global under Swift 6.
    public static var attributes: DownloadActivityAttributes {
        DownloadActivityAttributes(
            downloadID: "11111111-1111-1111-1111-111111111111",
            kindToken: "https"
        )
    }

    /// Frame 5's Live Activity: `3.61 of 5.73 GB · 48.2 MB/s`, 63 %, 44 s remaining.
    public static var liveState: DownloadActivityAttributes.ContentState {
        DownloadActivityAttributes.ContentState(
            filename: "ubuntu-24.04.1-desktop-amd64.iso",
            receivedBytes: 3_610_000_000,
            totalBytes: 5_730_000_000,
            fraction: 0.63,
            speed: 48_200_000,
            eta: 44,
            isAggregate: false,
            activeCount: 4,
            isPaused: false,
            updatedAt: Date()
        )
    }

    /// The same transfer two minutes after the app was suspended: no ETA, and `updatedAt`
    /// deliberately in the past so `Text(_:style: .relative)` renders `2 min`.
    public static var staleState: DownloadActivityAttributes.ContentState {
        DownloadActivityAttributes.ContentState(
            filename: "ubuntu-24.04.1-desktop-amd64.iso",
            receivedBytes: 3_610_000_000,
            totalBytes: 5_730_000_000,
            fraction: 0.63,
            speed: 0,
            eta: nil,
            isAggregate: false,
            activeCount: 4,
            isPaused: false,
            updatedAt: Date().addingTimeInterval(-120)
        )
    }

    /// The aggregate presentation — `3 downloads · 62%`.
    public static var aggregateState: DownloadActivityAttributes.ContentState {
        DownloadActivityAttributes.ContentState(
            filename: "",
            receivedBytes: 18_900_000_000,
            totalBytes: 30_500_000_000,
            fraction: 0.62,
            speed: 70_400_000,
            eta: 165,
            isAggregate: true,
            activeCount: 3,
            isPaused: false,
            updatedAt: Date()
        )
    }
}
