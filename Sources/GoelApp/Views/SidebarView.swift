import SwiftUI
import AppKit
import GoelCore

struct SidebarView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                group("Library") {
                    item("All files", "tray.full", .all)
                }
                group("Status") {
                    item(vm.localized("Active"), "arrow.down.circle", .active)
                    item(vm.localized("Paused"), "pause.circle", .paused)
                    item(vm.localized("Completed"), "checkmark.circle", .completed)
                    item(vm.localized("Seeding"), "arrow.up.circle", .seeding)
                }
                group("Type") {
                    item("Video", "film", .type(.video))
                    item("Disc images", "opticaldisc", .type(.iso))
                    item("Archives", "doc.zipper", .type(.archive))
                    item("Apps", "app.badge", .type(.app))
                }
                MediaJobsSidebarGroup(center: vm.mediaJobs)
                serversGroup
            }
            .padding(10)
        }
        .background(.regularMaterial)
        .accessibilityLabel("Library sidebar")
        // The status probe is unauthenticated TCP + DNS only — it must never carry credentials.
        .task {
            await vm.refreshServerStatuses()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppViewModel.serverStatusRefreshSeconds * 1_000_000_000)
                if NSApplication.shared.isActive { await vm.refreshServerStatuses() }
            }
        }
        .onChange(of: vm.servers.map(\.id)) { Task { await vm.refreshServerStatuses() } }
    }

    @ViewBuilder
    private var serversGroup: some View {
        HStack {
            Text("SERVERS")
                .scaledFont(size: 10.5, weight: .bold)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Servers")
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { vm.presentNewServer() } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add SFTP server")
            .a11yButton("Add SFTP server")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)

        if vm.servers.isEmpty {
            Text("Add an SFTP server to browse and transfer files.")
                .scaledFont(size: 11)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        } else {
            ForEach(vm.servers) { server in
                serverItem(server)
            }
        }
    }

    private func serverItem(_ server: SFTPConnection) -> some View {
        let selected = vm.selectedServer == server.id
        let transferring = vm.sftpTransfers.contains { $0.connectionID == server.id && $0.isActive }
        let meta = vm.serverMeta[server.id]
        return Button {
            vm.selectServer(server.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "lock.rectangle.on.rectangle")
                    .font(.system(size: 15)).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.label).scaledFont(size: 13).lineLimit(1)
                        Spacer(minLength: 4)
                        if transferring {
                            ProgressView()
                                .controlSize(.small)
                                .tint(selected ? Theme.onIndigo : Theme.accent)
                                .help("Transferring…")
                                .a11yDecorative()
                        } else {
                            liveDot(meta?.reachability ?? .unknown,
                                    detail: meta?.offlineDetail, selected: selected)
                        }
                    }
                    serverSubtitle(server, meta: meta, selected: selected)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.indigo : Color.clear)
            )
            // Ink must derive from the fill, not hard-coded white: `indigo` is light in three themes, measuring 1.93:1.
            .foregroundStyle(selected ? Theme.onIndigo : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yGroup(
            label: A11y.sentence("Server", server.label, server.host),
            value: A11y.sentence(
                transferring ? "Transferring" : (meta?.reachability ?? .unknown).accessibilityName,
                meta?.reachability == .offline ? meta?.offlineDetail : nil,
                meta?.latencyMS.map { "\($0) milliseconds" },
                meta?.os?.pretty),
            hint: "Activate to browse this server's files.")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Edit server")) { vm.presentEditServer(server) }
        .accessibilityAction(named: Text("Reconnect")) { vm.reconnectServer(server.id) }
        .accessibilityAction(named: Text("Disconnect")) { vm.disconnectServer(server.id) }
        .accessibilityAction(named: Text("Test connection")) { vm.testServerConnection(server) }
        .contextMenu { serverMenu(server) }
    }

    @ViewBuilder
    private func serverMenu(_ server: SFTPConnection) -> some View {
        let engaged = vm.isServerEngaged(server.id)
        let meta = vm.serverMeta[server.id]

        if vm.selectedServer != server.id {
            Button("Connect") { vm.selectServer(server.id) }
        }
        Button("Reconnect") { vm.reconnectServer(server.id) }
        Button("Disconnect") { vm.disconnectServer(server.id) }
            .disabled(!engaged)
        Button(vm.serverTestsInFlight.contains(server.id) ? "Testing…" : "Test Connection") {
            vm.testServerConnection(server)
        }
        .disabled(vm.serverTestsInFlight.contains(server.id))

        Divider()

        Button("Copy SFTP Address") {
            vm.copyToPasteboard(vm.sftpLocator(for: server, remotePath: "/"))
        }
        Button("Copy Host") { vm.copyToPasteboard(server.host) }
        if let ip = meta?.ip, ip != server.host {
            Button("Copy IP Address") { vm.copyToPasteboard(ip) }
        }

        Divider()

        Button(vm.hostKeyReadsInFlight.contains(server.id) ? "Reading Host Key…" : "Show Host Key…") {
            vm.showHostKey(server)
        }
        .disabled(vm.hostKeyReadsInFlight.contains(server.id))
        Button("Forget Host Key") { vm.forgetHostKey(server) }
            // Deliberately still enabled when the pin record is unreadable — that is the state this clears.
            .disabled(!vm.hasHostKeyRecord(server))
            .help("Use only after a legitimate server rekey. Goel will ask you to confirm the new key.")

        Divider()

        Button("Open in Terminal") { vm.openServerInTerminal(server) }
            .help("Opens an ssh session in your terminal, outside Goel’s host-key pinning.")

        Divider()

        Button("Edit…") { vm.presentEditServer(server) }
        Button("Remove", role: .destructive) {
            vm.requestConfirm(
                title: "Remove “\(server.label)”?",
                message: "This deletes the saved connection and its Keychain password. Files on the server are not touched.",
                confirmTitle: "Remove",
                destructive: true
            ) { vm.removeServer(server.id) }
        }
    }

    private func liveDot(_ reachability: ServerReachability, detail: String?, selected: Bool) -> some View {
        let color = selected && reachability == .unknown ? Theme.onIndigoSecondary : reachability.tint
        let help = reachability == .offline
            ? (detail.map { "Offline — \($0)" } ?? "Offline")
            : reachability.help
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: reachability == .online ? color.opacity(0.9) : .clear, radius: 3)
            .help(help)
    }

    @ViewBuilder
    private func serverSubtitle(_ server: SFTPConnection, meta: ServerMeta?, selected: Bool) -> some View {
        let secondary = selected ? Theme.onIndigoSecondary : Color.secondary
        let hostLine: String = {
            if let ip = meta?.ip, ip != server.host { return "\(server.host) · \(ip)" }
            return server.host
        }()
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(hostLine)
                    .scaledFont(size: 10.5, design: .monospaced)
                    .foregroundStyle(secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let ms = meta?.latencyMS, meta?.reachability == .online {
                    Text("\(ms)ms")
                        .scaledFont(size: 9.5, weight: .medium, monospacedDigit: true)
                        .foregroundStyle(selected ? Theme.onIndigoSecondary : Color(nsColor: .tertiaryLabelColor))
                }
                Spacer(minLength: 0)
            }
            if let os = meta?.os {
                osChip(os, selected: selected)
            }
        }
    }

    private func osChip(_ os: ServerOS, selected: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: os.symbol).font(.system(size: 8.5))
            Text(os.label).scaledFont(size: 9.5, weight: .semibold).lineLimit(1)
        }
        .foregroundStyle(selected ? Theme.onIndigo : os.tint)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(
            Capsule().fill(selected ? Theme.onIndigo.opacity(0.18) : os.tint.opacity(0.14))
        )
        .help(os.pretty)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 10.5, weight: .bold)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
        content()
    }

    private func item(_ label: String, _ symbol: String, _ filter: SidebarFilter) -> some View {
        let selected = vm.filter == filter && vm.selectedServer == nil
        return Button {
            vm.closeServerBrowser()
            vm.filter = filter
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(label)
                    .scaledFont(size: 13)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(vm.count(for: filter))")
                    .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(selected ? Theme.onAccent.opacity(0.25) : Color.primary.opacity(0.08))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.accent : Color.clear)
            )
            .foregroundStyle(selected ? Theme.onAccent : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yGroup(label: label, value: "\(vm.count(for: filter)) downloads",
                   hint: "Activate to filter the list.")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Must stay its own view observing the center: nested observables do not propagate updates.
private struct MediaJobsSidebarGroup: View {

    @ObservedObject var center: MediaJobCenter

    var body: some View {
        if center.liveCount > 0 {
            Text("MEDIA")
                .scaledFont(size: 10.5, weight: .bold)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .accessibilityLabel("Media")
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text("Converting")
                    .scaledFont(size: 13)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(center.liveCount)")
                    .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accent.opacity(0.18)))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .a11yGroup(label: "Converting",
                       value: "\(center.liveCount) media job\(center.liveCount == 1 ? "" : "s") in progress")
        }
    }
}
