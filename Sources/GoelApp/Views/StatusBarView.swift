import SwiftUI
import GoelCore

struct StatusBarView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    @EnvironmentObject private var sftpStore: SFTPTransferStore
    @State private var showTransfers = false
    @State private var showCustomCap = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 14) {
            snail
            stat(.down, speed: telemetry.displayedCombinedSpeed.down)
            stat(.up, speed: telemetry.displayedCombinedSpeed.up)
            if !activeTransfers.isEmpty { transfersIndicator }
            queueFinish
            selectionEcho
            Spacer()
            Text(L10n.t("Queue profile")).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
                .a11yDecorative()
            profilePicker
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 38)
        .background(.bar)
        .accessibilityLabel(L10n.t("Status bar"))
    }

    private var activeTransfers: [SFTPTransfer] { vm.sftpTransfers.filter { $0.isActive } }

    /// "1.2 GB left · done ≈ 14:32": answers "can I close the lid yet?" without adding up rows.
    @ViewBuilder
    private var queueFinish: some View {
        let overview = QueueOverview(tasks: vm.tasks) { telemetry.displaySpeed(for: $0) }
        if let done = overview.doneText() {
            Text(L10n.t("%1$@ left · %2$@", overview.remainingBytes.byteString, done))
                .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(L10n.t("When the running and queued downloads finish at the current combined speed"))
        }
    }

    /// With the panel closed (or several rows picked) nothing else confirms what is selected.
    @ViewBuilder
    private var selectionEcho: some View {
        let selected = vm.selectedTasks
        if !selected.isEmpty, !vm.detailPanelVisible || selected.count > 1 {
            let bytes = selected.reduce(Int64(0)) { $0 + ($1.totalBytes ?? $1.bytesDownloaded) }
            Text(SelectionAggregate.statusLine(count: selected.count, totalBytes: bytes))
                .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var transfersIndicator: some View {
        Button { showTransfers.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down.circle").scaledFont(size: Theme.TextSize.body)
                Text("\(activeTransfers.count)").scaledFont(size: Theme.TextSize.body, weight: .semibold, monospacedDigit: true)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.indigo.opacity(0.16)))
            .foregroundStyle(Theme.indigo)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("SFTP transfers"))
        .a11yButton(L10n.t("SFTP transfers"), hint: L10n.t("Activate to list transfers in progress."))
        .accessibilityValue(L10n.t("%d in progress", activeTransfers.count))
        .popover(isPresented: $showTransfers, arrowEdge: .bottom) { transfersPopover }
    }

    private var transfersPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.t("SFTP Transfers")).scaledFont(size: Theme.TextSize.body, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if vm.sftpTransfers.contains(where: { !$0.isActive }) {
                    Button(L10n.t("Clear")) { vm.clearFinishedSFTPTransfers() }
                        .buttonStyle(.plain).scaledFont(size: Theme.TextSize.meta).foregroundStyle(Theme.accent)
                        .accessibilityLabel(L10n.t("Clear finished transfers"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.sftpTransfers) { t in
                        SFTPTransferRow(
                            transfer: t, density: .compact,
                            serverLabel: vm.server(t.connectionID)?.label ?? L10n.t("Server"),
                            onCancel: { vm.requestCancelSFTPTransfer(t.id) },
                            onRetry: { vm.retrySFTPTransfer(t.id) },
                            onPause: { vm.pauseSFTPTransfer(t.id) },
                            onResume: { vm.resumeSFTPTransfer(t.id) },
                            onShowRemoteFolder: {
                                showTransfers = false
                                vm.revealSFTPTransfer(t)
                            })
                        Divider().opacity(0.3)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 320)
    }

    private var snail: some View {
        // ManagedPolicy key: without this check a forced value silently reverts on the next apply.
        let locked = vm.managedPolicy.isLocked(.speedLimitEnabled)
        return Button(action: vm.toggleSnail) {
            HStack(spacing: 6) {
                Snail()
                    .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 15)
                Text(SpeedProfileText.pill(limitEnabled: vm.settings.speedLimitEnabled,
                                           profile: vm.settings.selectedProfile))
                    .scaledFont(size: Theme.TextSize.meta, weight: .medium, monospacedDigit: true)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(vm.settings.speedLimitEnabled ? Theme.orange.opacity(0.18) : Theme.fillRest)
            )
            .foregroundStyle(vm.settings.speedLimitEnabled ? Theme.orange : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(locked ? AppViewModel.managedFootnote
                     : A11y.sentence(L10n.t("Toggle global speed limit"),
                                     SpeedProfileText.summary(vm.settings.selectedProfile)))
        .a11yButton(L10n.t("Global speed limit"),
                    hint: locked ? AppViewModel.managedFootnote
                                 : L10n.t("Activate to turn the speed limit on or off."))
        .accessibilityValue(vm.settings.speedLimitEnabled
                            ? A11y.sentence(L10n.t("On, %@ profile", vm.settings.selectedProfileName),
                                            SpeedProfileText.spokenLimits(vm.settings.selectedProfile))
                            : L10n.t("Off, unlimited"))
        .contextMenu { speedMenu }
        .accessibilityAction(named: Text(L10n.t("Custom speed limit"))) { showCustomCap = true }
        .popover(isPresented: $showCustomCap, arrowEdge: .top) {
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
        Button(L10n.t("Custom… ↓ ↑")) { showCustomCap = true }
    }

    private static let presetCaps: [Int64] = [500_000, 1_000_000, 5_000_000, 10_000_000]

    private func stat(_ direction: SpeedDirection, speed: Double) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: direction.symbol).scaledFont(size: Theme.TextSize.meta)
                Text(speed.speedString).scaledFont(size: Theme.TextSize.body, weight: .semibold, monospacedDigit: true)
                    .frame(width: 72, alignment: .leading)
            }
            .foregroundStyle(direction.tint)
            .a11yGroup(label: direction == .up ? L10n.t("Total upload speed") : L10n.t("Total download speed"),
                       value: A11y.speed(speed))
            GlobalSpeedSparkline(direction: direction)
        }
    }

    /// The Speed & Connections pane edits the active profile, so editing one makes it the active one.
    private func editProfile(_ name: String) {
        if name != vm.settings.selectedProfileName { vm.setProfile(name) }
        SettingsRoute.shared.request(.traffic)
        openSettings()
    }

    private var profilePicker: some View {
        HStack(spacing: 2) {
            ForEach(vm.settings.profiles) { profile in
                let selected = profile.name == vm.settings.selectedProfileName
                Button {
                    vm.setProfile(profile.name)
                } label: {
                    Text(profile.name)
                        .scaledFont(size: Theme.TextSize.meta, weight: .medium)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(selected ? Theme.accent : Color.clear)
                        )
                        // Derived ink: white on the accent fill measures 2.00–2.42:1 in 3 of 4 themes.
                        .foregroundStyle(selected ? Theme.onAccent : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(SpeedProfileText.queueSummary(profile, limitEnabled: vm.settings.speedLimitEnabled))
                .contextMenu {
                    Button(L10n.t("Edit Profile…")) { editProfile(profile.name) }
                        .disabled(profile.name != vm.settings.selectedProfileName
                                  && vm.managedPolicy.isLocked(.selectedProfileName))
                }
                .accessibilityLabel(L10n.t("%@ queue profile", profile.name))
                .accessibilityValue(SpeedProfileText.spokenQueueSummary(
                    profile, limitEnabled: vm.settings.speedLimitEnabled))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(named: L10n.t("Edit Profile")) { editProfile(profile.name) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.field).fill(Theme.fillRest))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Queue profile"))
    }
}

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
