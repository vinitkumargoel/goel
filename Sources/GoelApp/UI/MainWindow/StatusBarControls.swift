import SwiftUI
import GoelCore

/// "Limit off" / "On, Medium profile": toggles the global speed limit; right-click for presets
/// and a custom cap.
struct StatusSpeedLimitChip: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var showsCustomCap = false
    @State private var hovered = false

    private static let presetCaps: [Int64] = [500_000, 1_000_000, 5_000_000, 10_000_000]

    var body: some View {
        // ManagedPolicy key: without this check a forced value silently reverts on the next apply.
        let locked = vm.managedPolicy.isLocked(.speedLimitEnabled)
        let on = vm.settings.speedLimitEnabled
        Button(action: vm.toggleSnail) {
            HStack(spacing: Studio.Space.xs) {
                Snail()
                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                Text(SpeedProfileText.pill(limitEnabled: on, profile: vm.settings.selectedProfile))
                    .studioFont(.callout.size(11.5).tabular)
                    .lineLimit(1)
            }
            .foregroundStyle(on ? Studio.Palette.warn : hovered ? Studio.Palette.ink : Studio.Palette.ink2)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(Capsule().fill(on ? Studio.Palette.warnSoft
                                          : hovered ? Studio.Palette.well : Studio.Palette.card))
            .overlay {
                if !on { Capsule().strokeBorder(Studio.Palette.hairline, lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(locked)
        .opacity(locked ? 0.55 : 1)
        .help(locked ? AppViewModel.managedFootnote
                     : A11y.sentence(L10n.t("Toggle global speed limit"),
                                     SpeedProfileText.summary(vm.settings.selectedProfile)))
        .a11yButton(L10n.t("Global speed limit"),
                    hint: locked ? AppViewModel.managedFootnote
                                 : L10n.t("Activate to turn the speed limit on or off."))
        .accessibilityValue(on
                            ? A11y.sentence(L10n.t("On, %@ profile", vm.settings.selectedProfileName),
                                            SpeedProfileText.spokenLimits(vm.settings.selectedProfile))
                            : L10n.t("Off, unlimited"))
        .contextMenu { speedMenu }
        .accessibilityAction(named: Text(L10n.t("Custom speed limit"))) { showsCustomCap = true }
        .popover(isPresented: $showsCustomCap, arrowEdge: .top) {
            SpeedCapPopover().environmentObject(vm)
        }
    }

    @ViewBuilder
    private var speedMenu: some View {
        Button(vm.settings.speedLimitEnabled ? L10n.t("Turn Limit Off") : L10n.t("Turn Limit On")) { vm.toggleSnail() }
        Divider()
        ForEach(Self.presetCaps, id: \.self) { cap in
            Button(L10n.t("↓ %@", Double(cap).speedString)) {
                vm.applyCustomSpeedCap(down: cap, up: vm.settings.selectedProfile.maxUploadBytesPerSec)
            }
        }
        Divider()
        Button(L10n.t("Custom… ↓ ↑")) { showsCustomCap = true }
    }
}

/// Low · Medium · High: the queue profile as a small segmented control. Right-click a segment
/// to edit that profile in Settings.
struct StatusProfilePicker: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        StudioSegmentedControl(
            selection: Binding(get: { vm.activeProfileName }, set: { vm.setProfile($0) }),
            segments: vm.queueProfiles.map(segment),
            size: .small,
            accessibilityLabel: L10n.t("Queue profile"))
    }

    private func segment(_ profile: TrafficProfile) -> StudioSegment<String> {
        StudioSegment(
            profile.name, title: profile.name,
            accessibilityLabel: L10n.t("%@ queue profile", profile.name),
            accessibilityValue: vm.spokenQueueSummary(for: profile),
            help: vm.queueSummary(for: profile),
            actions: [StudioSegmentAction(title: L10n.t("Edit Profile…"),
                                          isEnabled: vm.canEditProfile(named: profile.name)) {
                vm.prepareToEditProfile(named: profile.name)
                openSettings()
            }])
    }
}

/// The speed-limit glyph (Lucide's snail), stroked by the caller. Also drawn by the menu bar.
struct Snail: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()

        // Source SVG: M2 18 h6 a6 6 0 0 1 6 -6 a5 5 0 0 1 5 5 v1
        path.move(to: p(2, 18))
        path.addLine(to: p(8, 18))
        path.addCurve(to: p(14, 12), control1: p(8, 14.69), control2: p(10.69, 12))
        path.addCurve(to: p(19, 17), control1: p(16.76, 12), control2: p(19, 14.24))
        path.addLine(to: p(19, 18))

        // Source SVG: circle cx7 cy16 r4
        path.addEllipse(in: CGRect(x: rect.minX + 3 * sx, y: rect.minY + 12 * sy,
                                   width: 8 * sx, height: 8 * sy))

        // Source SVG: M19 12 V8 … l-1.5 1.5 / l1.5 1.5
        path.move(to: p(19, 12))
        path.addLine(to: p(19, 8))
        path.move(to: p(17.5, 9.5))
        path.addLine(to: p(19, 8))
        path.addLine(to: p(20.5, 9.5))

        return path
    }
}

/// "3 failed": filters the list to Failed; its menu offers Retry All.
struct StatusFailedButton: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let failed = vm.count(for: .failed)
        if failed > 0 {
            Menu {
                Button(L10n.t("Show Failed")) { show() }
                Button(L10n.t("Retry All")) { vm.retryAllFailed() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(StudioFonts.font(.ui, size: 11, weight: 600))
                    Text(L10n.t("%d failed", failed)).studioFont(.small.weight(600).tabular)
                }
                .foregroundStyle(Studio.Palette.bad)
            } primaryAction: {
                show()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.t("Show failed downloads"))
            .accessibilityLabel(L10n.t("%d failed", failed))
            .accessibilityHint(L10n.t("Activate to show failed downloads."))
        }
    }

    private func show() {
        vm.closeServerBrowser()
        vm.filter = .failed
    }
}
