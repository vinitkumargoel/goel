import SwiftUI
import AppKit
import GoelCore

/// The left sidebar: Library / Status / Type groups with live counts, mirroring
/// the mockup's `.sidebar`.
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
                serversGroup
            }
            .padding(10)
        }
        .background(.regularMaterial)
        // Keep the sidebar's live server dots fresh: probe on appear and every
        // ~20s while the app is open (unauthenticated TCP + DNS — no credentials).
        .task {
            await vm.refreshServerStatuses()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppViewModel.serverStatusRefreshSeconds * 1_000_000_000)
                // Skip the sweep while the app is backgrounded/inactive — no point
                // probing every server when the sidebar can't be seen.
                if NSApplication.shared.isActive { await vm.refreshServerStatuses() }
            }
        }
        // Re-probe immediately when a server is added or removed.
        .onChange(of: vm.servers.map(\.id)) { Task { await vm.refreshServerStatuses() } }
    }

    /// The "Servers" group: each saved SFTP connection, plus an add button.
    @ViewBuilder
    private var serversGroup: some View {
        HStack {
            Text("SERVERS")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.tertiary)
            Spacer()
            Button { vm.presentNewServer() } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add SFTP server")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)

        if vm.servers.isEmpty {
            Text("Add an SFTP server to browse and transfer files.")
                .font(.system(size: 11))
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
                        Text(server.label).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 4)
                        // A live spinner while this server has an in-flight
                        // upload/download; otherwise the reachability dot, so a
                        // server reads as online/offline at a glance and a transfer
                        // stays visible even with the browser closed.
                        if transferring {
                            ProgressView()
                                .controlSize(.small)
                                .tint(selected ? Color.white : Theme.accent)
                                .help("Transferring…")
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
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
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
    }

    /// The live-status dot: green online / red offline / grey unknown, with a
    /// soft glow when online so it reads as "live".
    private func liveDot(_ reachability: ServerReachability, detail: String?, selected: Bool) -> some View {
        let color = selected && reachability == .unknown ? Color.white.opacity(0.7) : reachability.tint
        // When offline, prefer the specific reason (refused / unreachable / DNS)
        // over the generic "Offline" so the tooltip actually helps troubleshoot.
        let help = reachability == .offline
            ? (detail.map { "Offline — \($0)" } ?? "Offline")
            : reachability.help
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: reachability == .online ? color.opacity(0.9) : .clear, radius: 3)
            .help(help)
    }

    /// The second line under a server's name: host · IP, a latency read when
    /// online, and an OS chip once detected.
    @ViewBuilder
    private func serverSubtitle(_ server: SFTPConnection, meta: ServerMeta?, selected: Bool) -> some View {
        let secondary = selected ? Color.white.opacity(0.75) : Color.secondary
        HStack(spacing: 5) {
            Text(meta?.ip.map { "\(server.host) · \($0)" } ?? server.host)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(secondary)
                .lineLimit(1).truncationMode(.middle)
            if let ms = meta?.latencyMS, meta?.reachability == .online {
                Text("\(ms)ms")
                    .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.6) : Color(nsColor: .tertiaryLabelColor))
            }
            Spacer(minLength: 0)
            if let os = meta?.os {
                osChip(os, selected: selected)
            }
        }
    }

    /// A compact OS badge, e.g. a tinted dot + "Ubuntu 22.04 LTS".
    private func osChip(_ os: ServerOS, selected: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: os.symbol).font(.system(size: 8.5))
            Text(os.label).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : os.tint)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(
            Capsule().fill(selected ? Color.white.opacity(0.18) : os.tint.opacity(0.14))
        )
        .help(os.pretty)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
        content()
    }

    private func item(_ label: String, _ symbol: String, _ filter: SidebarFilter) -> some View {
        let selected = vm.filter == filter && vm.selectedServer == nil
        return Button {
            vm.selectedServer = nil
            vm.filter = filter
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(vm.count(for: filter))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.accent : Color.clear)
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
