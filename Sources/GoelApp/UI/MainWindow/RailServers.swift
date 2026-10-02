import SwiftUI
import GoelCore

/// Saved SFTP servers: live dot (or a transfer spinner), host, latency, OS chip, every action of
/// the old sidebar's context menu, Add SFTP server, and the all-transfers row.
struct RailServerSection: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Observed for the per-server "transferring" spinner and the transfers row.
    @EnvironmentObject private var sftpStore: SFTPTransferStore
    @State private var showAllTransfers = false

    var showsHeader = true
    var onPick: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.hair) {
            if showsHeader {
                RailSectionHeader(title: L10n.t("Servers")) { addButton }
            }
            if vm.servers.isEmpty {
                Text(L10n.t("Add an SFTP server to browse and transfer files."))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Studio.Space.sm)
                    .padding(.vertical, Studio.Space.xxs)
                if !showsHeader {
                    Button(L10n.t("Add SFTP Server"), systemImage: "plus") { vm.presentNewServer(); onPick() }
                        .buttonStyle(.studio(.soft, size: .small))
                        .padding(.horizontal, Studio.Space.sm)
                        .padding(.top, Studio.Space.xs)
                }
            } else {
                ForEach(vm.servers) { server in
                    RailServerRow(server: server, onPick: onPick)
                }
                transfersRow
            }
        }
        .sheet(isPresented: $showAllTransfers) {
            SFTPAllTransfersView().environmentObject(vm).environmentObject(sftpStore)
        }
    }

    var addButton: some View {
        StudioIconButton("plus", label: L10n.t("Add SFTP server"), size: .small) {
            vm.presentNewServer()
            onPick()
        }
    }

    private var transfersRow: some View {
        let summary = SFTPTransferSummary(vm.sftpTransfers)
        return RailRow(
            title: L10n.t("Transfers"),
            symbol: "arrow.up.arrow.down",
            count: summary.active > 0 ? summary.active : nil,
            help: L10n.t("Show transfers on every server"),
            accessibilityValue: A11y.sentence(L10n.t("%d active", summary.active),
                                              summary.failed > 0 ? L10n.t("%d failed", summary.failed) : nil)
        ) {
            showAllTransfers = true
        } trailing: {
            if summary.failed > 0 {
                Text(verbatim: "\(summary.failed)")
                    .studioFont(.monoSmall.weight(700))
                    .foregroundStyle(Studio.Palette.onAccent)
                    .padding(.horizontal, Studio.Space.xs)
                    .frame(minHeight: 17)
                    .background(Studio.Palette.bad, in: Capsule())
                    .help(L10n.t("%d failed", summary.failed))
            }
        }
    }
}

private struct RailServerRow: View {
    @EnvironmentObject private var vm: AppViewModel
    let server: SFTPConnection
    var onPick: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let selected = vm.selectedServer == server.id
        let transferring = vm.sftpTransfers.contains { $0.connectionID == server.id && $0.isActive }
        let meta = vm.serverMeta[server.id]
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
        return Button {
            vm.selectServer(server.id)
            onPick()
        } label: {
            HStack(alignment: .top, spacing: Studio.Space.sm) {
                Image(systemName: "server.rack")
                    .font(StudioFonts.font(.ui, size: 13, weight: 600))
                    .foregroundStyle(selected ? Studio.Palette.accent : Studio.Palette.ink3)
                    .frame(width: 18)
                    .padding(.top, Studio.Space.hair)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Studio.Space.xs) {
                        Text(server.label)
                            .studioFont(.bodyStrong)
                            .foregroundStyle(selected || hovered ? Studio.Palette.ink : Studio.Palette.ink2)
                            .lineLimit(1)
                        Spacer(minLength: Studio.Space.xxs)
                        if transferring {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                                .tint(Studio.Palette.accent)
                                .help(L10n.t("Transferring…"))
                                .accessibilityHidden(true)
                        } else {
                            liveDot(meta?.reachability ?? .unknown, detail: meta?.offlineDetail)
                        }
                    }
                    subtitle(meta: meta)
                }
            }
            .padding(.horizontal, Studio.Space.sm)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    shape.fill(Studio.Palette.card).studioElevation(.card)
                } else if hovered {
                    shape.fill(Studio.Palette.segment)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(L10n.t("Server"), server.label, server.host))
        .accessibilityValue(A11y.sentence(
            transferring ? L10n.t("Transferring") : (meta?.reachability ?? .unknown).accessibilityName,
            meta?.reachability == .offline ? meta?.offlineDetail : nil,
            meta?.latencyMS.map { L10n.t("%d milliseconds", $0) },
            meta?.os?.pretty))
        .accessibilityHint(L10n.t("Activate to browse this server’s files."))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text(L10n.t("Edit server"))) { vm.presentEditServer(server) }
        .accessibilityAction(named: Text(L10n.t("Reconnect"))) { vm.reconnectServer(server.id) }
        .accessibilityAction(named: Text(L10n.t("Disconnect"))) { vm.disconnectServer(server.id) }
        .accessibilityAction(named: Text(L10n.t("Test connection"))) { vm.testServerConnection(server) }
        .contextMenu { RailServerMenu(server: server) }
    }

    /// Online, offline and checking differ in shape as well as colour: a haloed dot, a cross, a
    /// hollow ring; with Differentiate Without Colour on, a tick, a cross and an ellipsis.
    @ViewBuilder
    private func liveDot(_ reachability: ServerReachability, detail: String?) -> some View {
        let help = reachability == .offline
            ? (detail.map { L10n.t("Offline — %@", $0) } ?? L10n.t("Offline"))
            : reachability.help
        Group {
            if differentiateWithoutColor {
                Image(systemName: reachability.studioSymbol)
                    .font(StudioFonts.font(.ui, size: 11, weight: 650))
                    .foregroundStyle(reachability.studioTint)
            } else {
                switch reachability {
                case .online:
                    Circle()
                        .fill(reachability.studioTint)
                        .frame(width: 7, height: 7)
                        .background { Circle().fill(Studio.Palette.goodSoft).frame(width: 13, height: 13) }
                case .offline:
                    Image(systemName: "xmark")
                        .font(StudioFonts.font(.ui, size: 9, weight: 800))
                        .foregroundStyle(reachability.studioTint)
                case .unknown:
                    Circle()
                        .strokeBorder(reachability.studioTint, lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                }
            }
        }
        .frame(width: 13, height: 13)
        .help(help)
    }

    @ViewBuilder
    private func subtitle(meta: ServerMeta?) -> some View {
        let hostLine: String = {
            if let ip = meta?.ip, ip != server.host { return "\(server.host) · \(ip)" }
            return server.host
        }()
        HStack(spacing: Studio.Space.xs) {
            Text(hostLine)
                .studioFont(.monoSmall.size(10.5))
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
            if let ms = meta?.latencyMS, meta?.reachability == .online {
                Text(verbatim: "\(ms)ms")
                    .studioFont(.monoSmall.size(10.5).weight(600))
                    .foregroundStyle(Studio.Palette.good)
            }
            Spacer(minLength: 0)
        }
        if let os = meta?.os {
            HStack(spacing: 3) {
                Image(systemName: os.symbol).font(StudioFonts.font(.ui, size: 8.5, weight: 600))
                Text(os.label).studioFont(.tiny.size(10).weight(650)).lineLimit(1)
            }
            .foregroundStyle(Studio.Palette.ink2)
            .padding(.horizontal, Studio.Space.xs)
            .padding(.vertical, 1.5)
            .background(Studio.Palette.segment, in: Capsule())
            .help(os.pretty)
        }
    }
}

/// Every action the old sidebar offered on a server, in the same order.
struct RailServerMenu: View {
    @EnvironmentObject private var vm: AppViewModel
    let server: SFTPConnection

    var body: some View {
        let engaged = vm.isServerEngaged(server.id)
        let meta = vm.serverMeta[server.id]

        if vm.selectedServer != server.id {
            Button(L10n.t("Connect")) { vm.selectServer(server.id) }
        }
        Button(L10n.t("Reconnect")) { vm.reconnectServer(server.id) }
        Button(L10n.t("Disconnect")) { vm.disconnectServer(server.id) }
            .disabled(!engaged)
        Button(vm.serverTestsInFlight.contains(server.id) ? L10n.t("Testing…") : L10n.t("Test Connection")) {
            vm.testServerConnection(server)
        }
        .disabled(vm.serverTestsInFlight.contains(server.id))

        Divider()

        Button(L10n.t("Copy SFTP Address")) {
            vm.copyToPasteboard(vm.sftpLocator(for: server, remotePath: "/"))
        }
        Button(L10n.t("Copy Host")) { vm.copyToPasteboard(server.host) }
        if let ip = meta?.ip, ip != server.host {
            Button(L10n.t("Copy IP Address")) { vm.copyToPasteboard(ip) }
        }

        Divider()

        Button(vm.hostKeyReadsInFlight.contains(server.id) ? L10n.t("Reading Host Key…") : L10n.t("Show Host Key…")) {
            vm.showHostKey(server)
        }
        .disabled(vm.hostKeyReadsInFlight.contains(server.id))
        Button(L10n.t("Forget Host Key")) { vm.forgetHostKey(server) }
            // Deliberately still enabled when the pin record is unreadable — that is the state this clears.
            .disabled(!vm.hasHostKeyRecord(server))
            .help(L10n.t("Use only after a legitimate server rekey. Goel° will ask you to confirm the new key."))

        Divider()

        Button(L10n.t("Open in Terminal")) { vm.openServerInTerminal(server) }
            .help(L10n.t("Opens an ssh session in your terminal, outside Goel°’s host-key pinning."))

        Divider()

        Button(L10n.t("Edit…")) { vm.presentEditServer(server) }
        Button(L10n.t("Remove"), role: .destructive) {
            vm.requestConfirm(
                title: L10n.t("Remove “%@”?", server.label),
                message: L10n.t("This deletes the saved connection and its Keychain "
                    + "password. Files on the server are not touched."),
                confirmTitle: L10n.t("Remove"),
                destructive: true
            ) { vm.removeServer(server.id) }
        }
    }
}
