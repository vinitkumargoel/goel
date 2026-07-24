import SwiftUI
import WidgetKit

/// The verification surface for every surface that cannot be screenshotted.
///
/// `simctl` has no command to lock the simulator, so a Lock Screen widget can never appear in a
/// screenshot; long-pressing the Dynamic Island cannot be scripted either; and the stale Live
/// Activity needs the app to be genuinely suspended mid-transfer. That would leave the three most
/// carefully designed surfaces in the product unverifiable.
///
/// So this screen renders the **real** widget views — the same types the extension instantiates,
/// out of `Shared/WidgetViews.swift` — inside containers at exact WidgetKit dimensions, on a dark
/// ground that reads like a Lock Screen. If a layout is wrong here it is wrong on the device.
///
/// Reached from Settings behind `#if DEBUG`.
public struct WidgetGalleryView: View {

    @State private var vibrantAccessories = true

    /// A section title (or its lowercased first word) to scroll to on appear. Only the
    /// screenshot harness passes this — there is no way to scroll a simulator from a script.
    private let scrollTo: String?

    public init(scrollTo: String? = nil) { self.scrollTo = scrollTo }

    public var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                intro

                group("Lock Screen accessories", id: "lock") {
                    Toggle("Vibrant rendering (as the Lock Screen draws them)", isOn: $vibrantAccessories)
                        .font(Theme.Typo.rowSubtitle)
                        .foregroundStyle(Theme.Color.label2)
                        .tint(Theme.Color.ember)

                    tile("accessoryCircular", width: 76, height: 76, ground: .circle) {
                        AccessoryCircularView(summary: lockSummary)
                    }
                    tile("accessoryCircular · active count", width: 76, height: 76, ground: .circle) {
                        AccessoryActiveCountView(summary: lockSummary)
                    }
                    tile("accessoryRectangular", width: 172, height: 76, ground: .glass) {
                        AccessoryRectangularView(summary: lockSummary)
                    }
                    tile("accessoryInline", width: 200, height: 24, ground: .plain) {
                        // The aggregate fixture, not the featured-transfer one: inline is a
                        // whole-queue line (`4 active · 21.4 GB`), so previewing it against a
                        // fixture whose remaining count is one download's reads as a bug.
                        AccessoryInlineView(summary: homeSummary)
                    }
                }
                // Accessories never render in full colour on a real Lock Screen — they are drawn
                // in a vibrant monochrome mode, which is why the views read the environment
                // rather than hardcoding ember. Overriding it here is the only way to see what
                // the Lock Screen will actually do without a Lock Screen.
                .environment(\.widgetRenderingMode, vibrantAccessories ? .vibrant : .fullColor)

                group("Home Screen", id: "home") {
                    tile("systemSmall · summary", width: 158, height: 158, ground: .card) {
                        HomeSummaryView(summary: homeSummary)
                    }
                    tile("systemSmall · fastest", width: 158, height: 158, ground: .card) {
                        HomeFastestView(
                            speed: fastest?.speed ?? 0,
                            filename: fastest?.filename,
                            history: WidgetSample.speedHistory
                        )
                    }
                    tile("systemMedium · queue", width: 338, height: 158, ground: .card) {
                        // Deep links are disabled here: tapping one inside the app would just
                        // re-open the app on top of itself.
                        HomeQueueView(items: WidgetSample.homeScreen.top, deepLinksEnabled: false)
                    }
                }

                group("Live Activity", id: "activity") {
                    tile("Lock Screen · live", width: 365, height: nil, ground: .card) {
                        LiveActivityLockScreenView(
                            state: WidgetSample.liveState,
                            downloadID: WidgetSample.attributes.downloadID,
                            kindToken: WidgetSample.attributes.kindToken,
                            isStale: false
                        )
                    }
                    tile("Lock Screen · aggregate", width: 365, height: nil, ground: .card) {
                        LiveActivityLockScreenView(
                            state: WidgetSample.aggregateState,
                            downloadID: DownloadActivityAttributes.aggregateID,
                            kindToken: WidgetGlyph.aggregateToken,
                            isStale: false
                        )
                    }
                    tile("Lock Screen · stale", width: 365, height: nil, ground: .card) {
                        LiveActivityLockScreenView(
                            state: WidgetSample.staleState,
                            downloadID: WidgetSample.attributes.downloadID,
                            kindToken: WidgetSample.attributes.kindToken,
                            isStale: true
                        )
                    }
                }

                group("Dynamic Island", id: "island") {
                    tile("Compact — while using another app", width: 172, height: 37, ground: .island(22)) {
                        HStack {
                            Image(systemName: WidgetGlyph.arrow)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SharedTheme.ember)
                            Spacer(minLength: 0)
                            WidgetProgressRing(fraction: WidgetSample.liveState.fraction)
                        }
                        .padding(.horizontal, 13)
                    }
                    tile("Minimal — sharing the Island", width: 46, height: 37, ground: .island(22)) {
                        WidgetProgressRing(fraction: WidgetSample.liveState.fraction)
                    }
                    tile("Expanded — long press", width: 340, height: nil, ground: .island(34)) {
                        IslandExpandedView(
                            state: WidgetSample.liveState,
                            downloadID: WidgetSample.attributes.downloadID,
                            kindToken: WidgetSample.attributes.kindToken,
                            isStale: false
                        )
                        .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
                    }
                    tile("Backgrounded — honest degradation", width: 340, height: nil, ground: .island(34)) {
                        IslandExpandedView(
                            state: WidgetSample.staleState,
                            downloadID: WidgetSample.attributes.downloadID,
                            kindToken: WidgetSample.attributes.kindToken,
                            isStale: true
                        )
                        .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
                    }
                }

                liveControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .onAppear {
            guard let scrollTo else { return }
            proxy.scrollTo(scrollTo, anchor: .top)
        }
        }
        .background(ground)
        .environment(\.colorScheme, .dark)
        .navigationTitle("Widget Gallery")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Data

    /// `visual.html` frame 5's fixture — 63 %, 2.1 GB left, four active. Every number the tiles
    /// draw is computed from a `SharedSnapshot` exactly as the real widgets compute theirs; only
    /// the snapshot itself is a fixture, so the layouts are verified even though the data is not
    /// live. Add a download and the real widget will show the real thing.
    private var lockSummary: WidgetSummary { WidgetSummary(snapshot: WidgetSample.lockScreen) }

    /// Frame 7's fixture — four active, 21.4 GB left, 47 %, three rows.
    private var homeSummary: WidgetSummary { WidgetSummary(snapshot: WidgetSample.homeScreen) }

    private var fastest: SharedSnapshot.Item? {
        WidgetSample.homeScreen.top.max { $0.speed < $1.speed }
    }

    // MARK: - Chrome

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Real widget views, exact WidgetKit dimensions.")
                .font(Theme.Typo.rowTitle)
                .foregroundStyle(Theme.Color.label1)
            Text("simctl cannot lock the simulator, so this screen is how the Lock Screen surfaces get verified. Data is the mockup fixture; the shipping widgets read SharedSnapshot.")
                .font(Theme.Typo.rowSubtitle)
                .foregroundStyle(Theme.Color.label2)
        }
    }

    private var liveControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Live Activity controls")
            Button("Publish stale state to the running activity") {
                ActivityController.shared.publishStaleForDebug()
            }
            .font(Theme.Typo.rowTitle)
            .foregroundStyle(Theme.Color.ember)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.minHitTarget)
            .background(Theme.Color.elev2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Republishes with a staleDate already in the past, so the degraded presentation can be screenshotted on a device.")
                .font(Theme.Typo.rowSubtitle)
                .foregroundStyle(Theme.Color.label2)
        }
    }

    /// The Lock Screen ground from `visual.html`: two radial washes over black.
    private var ground: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color(red: 0x3B / 255, green: 0x1F / 255, blue: 0x12 / 255), .clear],
                center: UnitPoint(x: 0.22, y: 0.08),
                startRadius: 0,
                endRadius: 460
            )
            RadialGradient(
                colors: [Color(red: 0x10 / 255, green: 0x22 / 255, blue: 0x2E / 255), .clear],
                center: UnitPoint(x: 0.82, y: 0.92),
                startRadius: 0,
                endRadius: 460
            )
        }
        .blur(radius: 24)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func group<Content: View>(
        _ title: String,
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            label(title)
            content()
        }
        .id(id)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .tracking(1)
            .foregroundStyle(Theme.Color.label3)
    }

    /// One labelled container, pinned to the family's real size.
    @ViewBuilder
    private func tile<Content: View>(
        _ title: String,
        width: CGFloat,
        height: CGFloat?,
        ground: TileGround,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.label2)

            content()
                .frame(width: width, height: height)
                .background(ground.background)
                .clipShape(ground.shape)
                .overlay(ground.border)
        }
    }
}

// MARK: - Tile grounds

/// The four surfaces a widget can sit on, so each tile reads the way the system would draw it.
private enum TileGround {
    /// Nothing behind it — the inline accessory sits directly on the wallpaper.
    case plain
    /// The Lock Screen's translucent chip — `rgba(120,120,128,.30)`, radius 12.
    case glass
    /// The same, but round, for the circular accessories.
    case circle
    /// A Home Screen / Live Activity card — `elev1` at 84 %, radius 22, `.5 pt` hairline.
    case card
    /// The Dynamic Island: pure black with a faint keyline, at the given radius.
    case island(CGFloat)

    private static let lockGlass = Color(uiColor: UIColor(
        red: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.30
    ))

    /// `@MainActor` because `WidgetSurface`'s initialiser is — `View` conformance implies it.
    @MainActor
    @ViewBuilder
    var background: some View {
        switch self {
        case .plain: Color.clear
        case .glass, .circle: Self.lockGlass
        case .card: WidgetSurface()
        case .island: Color.black
        }
    }

    var shape: AnyShape {
        switch self {
        case .plain: AnyShape(Rectangle())
        case .glass: AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .circle: AnyShape(Circle())
        case .card: AnyShape(RoundedRectangle(cornerRadius: SharedTheme.widgetRadius, style: .continuous))
        case let .island(radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder
    var border: some View {
        switch self {
        case .island(let radius):
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        default:
            EmptyView()
        }
    }
}

#Preview {
    NavigationStack {
        WidgetGalleryView()
    }
}
