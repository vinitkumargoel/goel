import SwiftUI
import GoelCore

/// Dedicated Settings sidebar tab for multi-path network aggregation.
struct AggregationSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    private var enabled: Bool { vm.settings.aggregationEnabled }
    private var usableCount: Int { vm.usableAggregationAdapters.count }
    private var inactiveReason: AggregationPolicy.SinglePathReason? { vm.aggregationInactiveReason }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusBanner
                .padding(.bottom, 18)

            masterToggleCard
                .padding(.bottom, 18)

            if enabled {
                adaptersSection
                    .padding(.bottom, 18)
                optionsSection
                    .padding(.bottom, 18)
            }

            tipsFooter
        }
        .onAppear { vm.beginAggregationLiveUpdates() }
        .onDisappear { vm.endAggregationLiveUpdates() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aggregation")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Multi-path HTTP downloads across network adapters")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: - Status

    private var statusBanner: some View {
        let active = enabled && inactiveReason == nil && usableCount >= 2
        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(active ? Theme.green : (enabled ? Theme.orange : Color.secondary.opacity(0.35)))
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(active ? "Multi-path ready" : (enabled ? "Multi-path idle" : "Multi-path off"))
                    .font(.system(size: 13, weight: .semibold))
                Text(statusDetail())
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if enabled {
                Button {
                    vm.refreshAggregationState()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }

    private func statusDetail() -> String {
        if !enabled {
            return "Turn on multi-path below, then select at least two adapters with independent internet paths."
        }
        if let reason = inactiveReason {
            return reason.rawValue
        }
        if usableCount < 2 {
            return "Need at least two eligible adapters. Enable expensive networks if using a phone hotspot."
        }
        return "\(usableCount) adapters will share ranged HTTP segments · \(vm.settings.aggregationStreamsPerAdapter) stream(s) each."
    }

    // MARK: - Master toggle

    private var masterToggleCard: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable multi-path downloads")
                    .font(.system(size: 13.5, weight: .medium))
                Text("Split large HTTP downloads across selected adapters using byte ranges. Default off.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            SettingSwitch(isOn: setting(vm, \.aggregationEnabled))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(enabled ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(enabled ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Adapters

    private var adaptersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ADAPTERS")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(selectionCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if vm.networkAdapters.isEmpty {
                emptyAdapters
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.networkAdapters) { adapter in
                        AdapterRow(adapter: adapter)
                    }
                }
            }

            Text("Leave none selected to use every eligible adapter. Two NICs on the same home router usually will not double speed.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectionCaption: String {
        let ids = vm.settings.aggregationAdapterIds
        if ids.isEmpty { return "Using all eligible" }
        return "\(ids.count) selected"
    }

    private var emptyAdapters: some View {
        HStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("No adapters found")
                    .font(.system(size: 13, weight: .medium))
                Text("Connect Wi‑Fi, Ethernet, or a phone hotspot, then refresh.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { vm.refreshAggregationState() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(Theme.hairline)
        )
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OPTIONS")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)

            SetRow(name: "Include expensive networks",
                   desc: "Allow cellular and personal hotspot (uses mobile data).") {
                SettingSwitch(isOn: setting(vm, \.aggregationIncludeExpensive))
            }
            SetRow(name: "Allow paths outside VPN",
                   desc: "Dangerous: physical NICs may bypass an active VPN tunnel.") {
                SettingSwitch(isOn: setting(vm, \.aggregationAllowOutsideVPN))
            }
            SetRow(name: "Streams per adapter",
                   desc: "Parallel range connections targeted on each adapter (1–8).") {
                HStack(spacing: 8) {
                    Stepper("", value: Binding(
                        get: { min(8, max(1, vm.settings.aggregationStreamsPerAdapter)) },
                        set: { newValue in
                            vm.update { $0.aggregationStreamsPerAdapter = min(8, max(1, newValue)) }
                        }
                    ), in: 1...8)
                    .labelsHidden()
                    Text("\(vm.settings.aggregationStreamsPerAdapter)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .frame(width: 22, alignment: .trailing)
                }
            }
            SetRow(name: "Check path diversity",
                   desc: "Warn when adapters appear to share one public IP (same WAN).") {
                SettingSwitch(isOn: setting(vm, \.aggregationPathDiversityProbe))
            }
        }
    }

    // MARK: - Tips

    private var tipsFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW IT WORKS")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.tertiary)
            tipRow(icon: "arrow.triangle.branch",
                   text: "Ranged HTTP segments bind to different adapters (not OS link aggregation).")
            tipRow(icon: "wifi.exclamationmark",
                   text: "Best with independent uplinks (e.g. home fiber + phone hotspot).")
            tipRow(icon: "list.bullet.rectangle",
                   text: "While downloading, open the Connections tab to see which adapter each segment uses.")
            tipRow(icon: "lock.shield",
                   text: "Multi-path is blocked with a system/manual proxy, or when a VPN is up (unless allowed).")
        }
        .padding(.top, 8)
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Adapter row

private struct AdapterRow: View {
    @EnvironmentObject private var vm: AppViewModel
    let adapter: NetworkAdapter

    private var selected: Bool {
        vm.settings.aggregationAdapterIds.isEmpty
            || vm.settings.aggregationAdapterIds.contains(adapter.bsdName)
    }

    private var disabled: Bool {
        adapter.isExpensive && !vm.settings.aggregationIncludeExpensive
    }

    private var participating: Bool { selected && !disabled }

    var body: some View {
        Button {
            guard !disabled else { return }
            if vm.settings.aggregationAdapterIds.isEmpty {
                vm.update { $0.aggregationAdapterIds = vm.networkAdapters.map(\.bsdName) }
            }
            vm.toggleAggregationAdapter(adapter.bsdName)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: typeIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(participating ? Theme.accent : .secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        (participating ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.05)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(adapter.displayName.isEmpty ? adapter.bsdName : adapter.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(adapter.bsdName)
                            .font(.system(size: 10.5).monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if adapter.isExpensive {
                    Text("EXPENSIVE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.4)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.orange)
                }

                Image(systemName: participating ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(participating ? Theme.accent : Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(participating ? Theme.accent.opacity(0.06) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(participating ? Theme.accent.opacity(0.28) : Theme.hairline, lineWidth: 1)
            )
            .opacity(disabled ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled
              ? "Enable “Include expensive networks” to use this adapter"
              : "Click to include or exclude from multi-path")
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
        parts.append(adapter.type.capitalized)
        if let v4 = adapter.ipv4 { parts.append(v4) }
        else if let v6 = adapter.ipv6 { parts.append(v6) }
        parts.append(adapter.isUp ? "Up" : "Down")
        if disabled { parts.append("blocked") }
        return parts.joined(separator: " · ")
    }
}
