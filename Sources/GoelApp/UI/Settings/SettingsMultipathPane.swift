import SwiftUI
import GoelCore

/// Multi-path: split large HTTP downloads across network adapters.
struct MultipathSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Snapshots pass fixed adapters and skip the live adapter watch.
    private let previewAdapters: [NetworkAdapter]?

    init(previewAdapters: [NetworkAdapter]? = nil) {
        self.previewAdapters = previewAdapters
    }

    private var enabled: Bool { vm.settings.aggregationEnabled }
    private var adapters: [NetworkAdapter] { previewAdapters ?? vm.networkAdapters }
    private var usableCount: Int {
        previewAdapters.map { list in
            list.filter { $0.isUp && (!$0.isExpensive || vm.settings.aggregationIncludeExpensive) }.count
        } ?? vm.usableAggregationAdapters.count
    }
    private var inactiveReason: AggregationPolicy.SinglePathReason? {
        previewAdapters == nil ? vm.aggregationInactiveReason : nil
    }

    var body: some View {
        SettingsPane(title: L10n.t("Multi-path"),
                     subtitle: L10n.t("Multi-path HTTP downloads across network adapters")) {
            statusCard
            if enabled {
                adaptersCard
            }
            if enabled {
                optionsCard
                    .settingsColumn(.trailing)
            }
            howItWorksCard
                .settingsColumn(.trailing)
        }
        .onAppear { if previewAdapters == nil { vm.beginAggregationLiveUpdates() } }
        .onDisappear { if previewAdapters == nil { vm.endAggregationLiveUpdates() } }
    }

    private var statusTone: StudioTone {
        let active = enabled && inactiveReason == nil && usableCount >= 2
        return active ? .good : (enabled ? .warn : .neutral)
    }

    private var statusCard: some View {
        let active = enabled && inactiveReason == nil && usableCount >= 2
        return SettingsCard(title: L10n.t("Aggregation"), symbol: "point.3.connected.trianglepath.dotted") {
            if enabled {
                Button(L10n.t("Refresh"), systemImage: "arrow.clockwise") { vm.refreshAggregationState() }
                    .buttonStyle(.studio(.ghost, size: .small))
            }
        } content: {
            SettingsCardBlock(showsDivider: false) {
                HStack(alignment: .top, spacing: Studio.Space.sm) {
                    StudioPill(active ? L10n.t("Multi-path ready")
                               : (enabled ? L10n.t("Multi-path idle") : L10n.t("Multi-path off")),
                               tone: statusTone)
                    Spacer(minLength: 0)
                }
                Text(statusDetail())
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            SettingRow(L10n.t("Enable multi-path downloads"),
                       detail: L10n.t("Split large HTTP downloads across selected adapters using byte ranges. Default off."),
                       isOn: setting(vm, \.aggregationEnabled))
        }
    }

    private func statusDetail() -> String {
        if !enabled {
            return L10n.t("Turn on multi-path below, then select at least two adapters with independent internet paths.")
        }
        if let reason = inactiveReason {
            return L10n.t(reason.rawValue)
        }
        if usableCount < 2 {
            return L10n.t("Need at least two eligible adapters. Enable expensive networks if using a phone hotspot.")
        }
        return L10n.t("%1$@ adapters will share ranged HTTP segments · %2$@ stream(s) each.",
                      String(usableCount), String(vm.settings.aggregationStreamsPerAdapter))
    }

    private var adaptersCard: some View {
        SettingsCard(title: L10n.t("Adapters"), symbol: "network",
                     footer: L10n.t("Leave none selected to use every eligible adapter. Two NICs on the same home router usually will not double speed.")) {
            Text(selectionCaption)
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink3)
        } content: {
            SettingsCardBlock(showsDivider: false) {
                if adapters.isEmpty {
                    emptyAdapters
                } else {
                    VStack(spacing: Studio.Space.s) {
                        ForEach(adapters) { adapter in
                            AdapterCard(adapter: adapter, allAdapters: adapters)
                        }
                    }
                }
            }
        }
    }

    private var selectionCaption: String {
        let ids = vm.settings.aggregationAdapterIds
        if ids.isEmpty { return L10n.t("Using all eligible") }
        return L10n.t("%d selected", ids.count)
    }

    private var emptyAdapters: some View {
        HStack(spacing: Studio.Space.m) {
            Image(systemName: "network.slash")
                .studioFont(.ui, size: 18, weight: 600)
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("No adapters found"))
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                Text(L10n.t("Connect Wi‑Fi, Ethernet, or a phone hotspot, then refresh."))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
            }
            Spacer()
            Button(L10n.t("Refresh")) { vm.refreshAggregationState() }
                .buttonStyle(.studio(.secondary, size: .small))
        }
        .padding(Studio.Space.ml)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
                .strokeBorder(Studio.Palette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [5]))
        )
    }

    private var optionsCard: some View {
        SettingsCard(title: L10n.t("Options"), symbol: "slider.horizontal.3") {
            SettingRow(L10n.t("Include expensive networks"),
                       detail: L10n.t("Allow cellular and personal hotspot (uses mobile data)."),
                       isOn: setting(vm, \.aggregationIncludeExpensive))
            SettingRow(L10n.t("Allow paths outside VPN"),
                       detail: L10n.t("Dangerous: physical NICs may bypass an active VPN tunnel."),
                       isOn: setting(vm, \.aggregationAllowOutsideVPN))
            SettingRow(L10n.t("Streams per adapter"),
                       detail: L10n.t("Parallel range connections targeted on each adapter (1–8).")) {
                HStack(spacing: Studio.Space.s) {
                    Text(verbatim: "\(vm.settings.aggregationStreamsPerAdapter)")
                        .studioFont(.monoBody)
                        .foregroundStyle(Studio.Palette.ink)
                        .frame(minWidth: 18, alignment: .trailing)
                        .accessibilityHidden(true)
                    Stepper("", value: streamsBinding, in: 1...8)
                        .labelsHidden()
                        .accessibilityLabel(L10n.t("Streams per adapter"))
                        .accessibilityValue("\(vm.settings.aggregationStreamsPerAdapter)")
                }
            }
            SettingRow(L10n.t("Check path diversity"),
                       detail: L10n.t("Warn when adapters appear to share one public IP (same WAN)."),
                       isOn: setting(vm, \.aggregationPathDiversityProbe))
        }
    }

    private var streamsBinding: Binding<Int> {
        Binding(
            get: { min(8, max(1, vm.settings.aggregationStreamsPerAdapter)) },
            set: { newValue in
                vm.update { $0.aggregationStreamsPerAdapter = min(8, max(1, newValue)) }
            }
        )
    }

    private var howItWorksCard: some View {
        SettingsCard(title: L10n.t("How it works"), symbol: "questionmark.circle") {
            SettingsCardBlock(showsDivider: false) {
                tipRow(icon: "arrow.triangle.branch",
                       text: L10n.t("Ranged HTTP segments bind to different adapters (not OS link aggregation)."))
                tipRow(icon: "wifi.exclamationmark",
                       text: L10n.t("Best with independent uplinks (e.g. home fiber + phone hotspot)."))
                tipRow(icon: "list.bullet.rectangle",
                       text: L10n.t("While downloading, open the Connections tab to see which adapter each segment uses."))
                tipRow(icon: "lock.shield",
                       text: L10n.t("Multi-path is blocked with a system/manual proxy, or when a VPN is up (unless allowed)."))
            }
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Studio.Space.sm) {
            Image(systemName: icon)
                .studioFont(.ui, size: 13, weight: 650)
                .foregroundStyle(Studio.Palette.accent)
                .frame(width: 18)
            Text(text)
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .a11yGroup(label: text)
    }
}

/// One network adapter you can include or leave out.
private struct AdapterCard: View {
    @EnvironmentObject private var vm: AppViewModel
    let adapter: NetworkAdapter
    let allAdapters: [NetworkAdapter]

    @State private var hovered = false

    private var selected: Bool {
        vm.settings.aggregationAdapterIds.isEmpty
            || vm.settings.aggregationAdapterIds.contains(adapter.bsdName)
    }

    private var disabled: Bool {
        adapter.isExpensive && !vm.settings.aggregationIncludeExpensive
    }

    private var participating: Bool { selected && !disabled }

    private var name: String { adapter.displayName.isEmpty ? adapter.bsdName : adapter.displayName }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.compactCard, style: .continuous)
        Button {
            guard !disabled else { return }
            if vm.settings.aggregationAdapterIds.isEmpty {
                // Read here on the main actor: `update` takes a @Sendable closure, and touching main-actor state inside one is a toolchain error.
                let ids = allAdapters.map(\.bsdName)
                vm.update { $0.aggregationAdapterIds = ids }
            }
            vm.toggleAggregationAdapter(adapter.bsdName)
        } label: {
            HStack(spacing: Studio.Space.m) {
                Image(systemName: typeIcon)
                    .studioFont(.ui, size: 14, weight: 650)
                    .foregroundStyle(participating ? Studio.Palette.accent : Studio.Palette.ink3)
                    .frame(width: 32, height: 32)
                    .background(participating ? Studio.Palette.accentSoft : Studio.Palette.segment,
                                in: RoundedRectangle(cornerRadius: Studio.Radius.artSmall, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Studio.Space.xs) {
                        Text(name)
                            .studioFont(.bodyStrong)
                            .foregroundStyle(Studio.Palette.ink)
                        Text(adapter.bsdName)
                            .studioFont(.monoSmall)
                            .foregroundStyle(Studio.Palette.ink3)
                    }
                    Text(subtitle)
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(2)
                }
                Spacer(minLength: Studio.Space.s)
                if adapter.isExpensive {
                    StudioPill(L10n.t("EXPENSIVE"), tone: .warn, showsDot: false)
                }
                Image(systemName: participating ? "checkmark.circle.fill" : "circle")
                    .studioFont(.ui, size: 17, weight: 500)
                    .foregroundStyle(participating ? Studio.Palette.accent : Studio.Palette.hairlineStrong)
            }
            .padding(.horizontal, Studio.Space.m)
            .padding(.vertical, Studio.Space.sm)
            .background(shape.fill(participating ? Studio.Palette.accentSoft.opacity(0.5) : Studio.Palette.well))
            .overlay(shape.strokeBorder(participating ? Studio.Palette.accentLine
                                        : hovered ? Studio.Palette.hairlineStrong : Studio.Palette.hairline,
                                        lineWidth: 1))
            .opacity(disabled ? 0.45 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(disabled
              ? L10n.t("Enable “Include expensive networks” to use this adapter")
              : L10n.t("Click to include or exclude from multi-path"))
        .a11yGroup(
            label: A11y.sentence(L10n.t("Network adapter"), name,
                                 adapter.isExpensive ? L10n.t("expensive") : nil),
            value: A11y.sentence(participating ? L10n.t("Included") : L10n.t("Not included"), subtitle),
            hint: disabled
                ? L10n.t("Turn on Include expensive networks to use this adapter.")
                : L10n.t("Activate to include or exclude it from multi-path downloads."))
        .accessibilityAddTraits(participating ? [.isButton, .isSelected] : .isButton)
    }

    private var typeIcon: String {
        switch adapter.type {
        case "wifi": return "wifi"
        case "wired": return "cable.connector"
        case "cellular": return "antenna.radiowaves.left.and.right"
        case "vpn": return "lock.shield"
        default: return "network"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(L10n.t(adapter.type.capitalized))
        if let v4 = adapter.ipv4 { parts.append(v4) }
        else if let v6 = adapter.ipv6 { parts.append(v6) }
        parts.append(adapter.isUp ? L10n.t("Up") : L10n.t("Down"))
        if disabled { parts.append(L10n.t("blocked")) }
        return parts.joined(separator: " · ")
    }
}
