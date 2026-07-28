import SwiftUI
import GoelCore

struct StatusBarView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var showTransfers = false

    var body: some View {
        HStack(spacing: 14) {
            snail
            stat(symbol: "arrow.down", speed: vm.displayedCombinedSpeed.down, color: Theme.green)
            stat(symbol: "arrow.up", speed: vm.displayedCombinedSpeed.up, color: Theme.teal)
            if !activeTransfers.isEmpty { transfersIndicator }
            Spacer()
            Text("Profile").scaledFont(size: 11).foregroundStyle(.tertiary)
                .a11yDecorative()
            profilePicker
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.bar)
        .accessibilityLabel("Status bar")
    }

    private var activeTransfers: [SFTPTransfer] { vm.sftpTransfers.filter { $0.isActive } }

    private var transfersIndicator: some View {
        Button { showTransfers.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down.circle").font(.system(size: 12))
                Text("\(activeTransfers.count)").scaledFont(size: 12, weight: .semibold, monospacedDigit: true)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.indigo.opacity(0.16)))
            .foregroundStyle(Theme.indigo)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("SFTP transfers")
        .a11yButton("SFTP transfers", hint: "Activate to list transfers in progress.")
        .accessibilityValue("\(activeTransfers.count) in progress")
        .popover(isPresented: $showTransfers, arrowEdge: .bottom) { transfersPopover }
    }

    private var transfersPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SFTP Transfers").scaledFont(size: 12, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if vm.sftpTransfers.contains(where: { !$0.isActive }) {
                    Button("Clear") { vm.clearFinishedSFTPTransfers() }
                        .buttonStyle(.plain).scaledFont(size: 11).foregroundStyle(Theme.accent)
                        .accessibilityLabel("Clear finished transfers")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.sftpTransfers) { t in
                        SFTPTransferRow(
                            transfer: t, density: .compact,
                            serverLabel: vm.server(t.connectionID)?.label ?? "Server",
                            onCancel: { vm.requestCancelSFTPTransfer(t.id) },
                            onRetry: { vm.retrySFTPTransfer(t.id) },
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
                Text(vm.settings.speedLimitEnabled ? vm.settings.selectedProfileName : "Unlimited")
                    .scaledFont(size: 11.5, weight: .medium)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(vm.settings.speedLimitEnabled ? Theme.orange.opacity(0.18) : Color.primary.opacity(0.08))
            )
            .foregroundStyle(vm.settings.speedLimitEnabled ? Theme.orange : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(locked ? AppViewModel.managedFootnote : "Toggle global speed limit")
        .a11yButton("Global speed limit",
                    hint: locked ? AppViewModel.managedFootnote
                                 : "Activate to turn the speed limit on or off.")
        .accessibilityValue(vm.settings.speedLimitEnabled
                            ? "On, \(vm.settings.selectedProfileName) profile"
                            : "Off, unlimited")
    }

    private func stat(symbol: String, speed: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(speed.speedString).scaledFont(size: 12, weight: .semibold, monospacedDigit: true)
                .frame(width: 72, alignment: .leading)
        }
        .foregroundStyle(color)
        .a11yGroup(label: symbol == "arrow.up" ? "Total upload speed" : "Total download speed",
                   value: A11y.speed(speed))
    }

    private var profilePicker: some View {
        HStack(spacing: 2) {
            ForEach(vm.settings.profiles) { profile in
                let selected = profile.name == vm.settings.selectedProfileName
                Button {
                    vm.setProfile(profile.name)
                } label: {
                    Text(profile.name)
                        .scaledFont(size: 11.5, weight: .medium)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Theme.accent : Color.clear)
                        )
                        // Derived ink: white on the accent fill measures 2.00–2.42:1 in 3 of 4 themes.
                        .foregroundStyle(selected ? Theme.onAccent : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(profile.name) speed profile")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speed profile")
    }
}

private struct Snail: Shape {
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
