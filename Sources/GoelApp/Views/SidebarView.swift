import SwiftUI
import AppKit
import GoelCore

struct SidebarView: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Observed for the per-server "transferring" dot.
    @EnvironmentObject private var sftpStore: SFTPTransferStore

    @AppStorage("sidebar.typesExpanded") private var typesExpanded = true
    /// Off by default: eight type rows at zero pushed Servers below the fold of a short window.
    @AppStorage("sidebar.showEmptyTypes") private var showEmptyTypes = false
    @AppStorage(TagColors.storageKey) private var tagColorsRaw = ""
    @State private var showAllTransfers = false
    /// Observed so the filter rows un-highlight while the RSS reader is showing.
    @ObservedObject private var rss = RSSReaderModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                group(L10n.t("Library")) { entries(SidebarCatalog.library) }
                group(L10n.t("Status")) { entries(SidebarCatalog.status) }
                typesGroup
                tagsGroup
                MediaJobsSidebarGroup(center: vm.mediaJobs)
                serversGroup
                RSSSidebarGroup()
            }
            .padding(10)
        }
        .background(.regularMaterial)
        .accessibilityLabel(L10n.t("Library sidebar"))
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

    private func entries(_ list: [SidebarEntry]) -> some View {
        ForEach(list) { entry in
            item(entry.title, entry.symbol, entry.filter,
                 shortcut: SidebarCatalog.shortcutFilters.firstIndex(of: entry.filter).map { $0 + 1 })
        }
    }

    /// Collapsible, and rows at zero hide behind "Show all types" — except the one being viewed.
    @ViewBuilder
    private var typesGroup: some View {
        let shown = SidebarCatalog.types.filter { entry in
            showEmptyTypes || vm.filter == entry.filter || vm.count(for: entry.filter) > 0
        }
        let hiddenCount = SidebarCatalog.types.count - shown.count
        disclosureHeader(L10n.t("Type"), expanded: $typesExpanded)
        if typesExpanded {
            entries(shown)
            if hiddenCount > 0 || showEmptyTypes {
                Button {
                    showEmptyTypes.toggle()
                } label: {
                    Text(showEmptyTypes ? L10n.t("Hide empty types") : L10n.t("Show all types"))
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(showEmptyTypes ? L10n.t("Hides types with no downloads.")
                                                  : L10n.t("Shows types with no downloads."))
            }
        }
    }

    private func disclosureHeader(_ title: String, expanded: Binding<Bool>) -> some View {
        Button {
            expanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(title.uppercased())
                    .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 8, weight: .bold)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    .a11yDecorative()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(expanded.wrappedValue ? L10n.t("Expanded") : L10n.t("Collapsed"))
        .accessibilityHint(expanded.wrappedValue ? L10n.t("Activate to collapse.") : L10n.t("Activate to expand."))
    }

    /// Only while some row carries a tag: an empty heading would advertise a feature with nothing in it.
    /// Tags are created per download (Add Tags…), so there is no "+" here.
    @ViewBuilder
    private var tagsGroup: some View {
        let tags = ListPresentation.tagCounts(vm.tasks)
        if !tags.isEmpty {
            group(L10n.t("Tags")) {
                ForEach(tags, id: \.tag) { entry in
                    item(entry.tag, nil, .tag(entry.tag), count: entry.count,
                         dot: tagColor(entry.tag))
                        .contextMenu { tagMenu(entry.tag) }
                        .accessibilityAction(named: Text(L10n.t("Rename tag"))) { vm.promptForTagRename(entry.tag) }
                }
            }
        }
    }

    private static let tagPalette: [KeyPath<ThemeColors, ThemeColors.Pair>] =
        [\.accent, \.green, \.orange, \.red, \.yellow, \.purple, \.teal, \.indigo]

    /// The user's pick, else stable per tag name; drawn from the theme so it follows Dracula and Nord.
    private func tagColor(_ tag: String) -> Color {
        let slot = TagColors.slot(for: tag, overrides: TagColors.decode(tagColorsRaw), slots: Self.tagPalette.count)
        return ThemePalette.color(Self.tagPalette[slot])
    }

    /// In `tagPalette` order.
    private static var tagColorNames: [String] {
        [L10n.t("Blue"), L10n.t("Green"), L10n.t("Orange"), L10n.t("Red"),
         L10n.t("Yellow"), L10n.t("Purple"), L10n.t("Teal"), L10n.t("Indigo")]
    }

    @ViewBuilder
    private func tagMenu(_ tag: String) -> some View {
        Button(L10n.t("Rename…")) { vm.promptForTagRename(tag) }
        Menu(L10n.t("Colour")) {
            ForEach(Array(Self.tagColorNames.enumerated()), id: \.offset) { slot, name in
                Button(name) { setTagColor(tag, slot: slot) }
            }
        }
        Divider()
        Button(L10n.t("Remove Tag from All Downloads"), role: .destructive) {
            vm.requestConfirm(
                title: L10n.t("Remove the tag “%@” from every download?", tag),
                message: L10n.t("The downloads stay; only the tag goes."),
                confirmTitle: L10n.t("Remove Tag"),
                destructive: true
            ) { vm.removeTagFromAll(tag) }
        }
    }

    private func setTagColor(_ tag: String, slot: Int) {
        tagColorsRaw = TagColors.encode(TagColors.setting(TagColors.decode(tagColorsRaw), tag: tag, slot: slot))
    }

    @ViewBuilder
    private var serversGroup: some View {
        HStack {
            Text(L10n.t("Servers").uppercased())
                .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.t("Servers"))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            IconButton(symbol: "plus", help: L10n.t("Add SFTP server")) { vm.presentNewServer() }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)

        if vm.servers.isEmpty {
            Text(L10n.t("Add an SFTP server to browse and transfer files."))
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        } else {
            ForEach(vm.servers) { server in
                serverItem(server)
            }
            SFTPTransfersSidebarRow(summary: SFTPTransferSummary(vm.sftpTransfers)) {
                showAllTransfers = true
            }
            .sheet(isPresented: $showAllTransfers) { SFTPAllTransfersView().environmentObject(vm).environmentObject(sftpStore) }
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
                    .scaledFont(size: Theme.TextSize.sheet).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.label).scaledFont(size: Theme.TextSize.body).lineLimit(1)
                        Spacer(minLength: 4)
                        if transferring {
                            ProgressView()
                                .controlSize(.small)
                                .tint(selected ? Theme.onIndigo : Theme.accent)
                                .help(L10n.t("Transferring…"))
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
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(selected ? Theme.indigo : Color.clear)
            )
            // Ink must derive from the fill, not hard-coded white: `indigo` is light in three themes, measuring 1.93:1.
            .foregroundStyle(selected ? Theme.onIndigo : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yGroup(
            label: A11y.sentence(L10n.t("Server"), server.label, server.host),
            value: A11y.sentence(
                transferring ? L10n.t("Transferring") : (meta?.reachability ?? .unknown).accessibilityName,
                meta?.reachability == .offline ? meta?.offlineDetail : nil,
                meta?.latencyMS.map { L10n.t("%d milliseconds", $0) },
                meta?.os?.pretty),
            hint: L10n.t("Activate to browse this server’s files."))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text(L10n.t("Edit server"))) { vm.presentEditServer(server) }
        .accessibilityAction(named: Text(L10n.t("Reconnect"))) { vm.reconnectServer(server.id) }
        .accessibilityAction(named: Text(L10n.t("Disconnect"))) { vm.disconnectServer(server.id) }
        .accessibilityAction(named: Text(L10n.t("Test connection"))) { vm.testServerConnection(server) }
        .contextMenu { serverMenu(server) }
    }

    @ViewBuilder
    private func serverMenu(_ server: SFTPConnection) -> some View {
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
                message: L10n.t("This deletes the saved connection and its Keychain password. Files on the server are not touched."),
                confirmTitle: L10n.t("Remove"),
                destructive: true
            ) { vm.removeServer(server.id) }
        }
    }

    private func liveDot(_ reachability: ServerReachability, detail: String?, selected: Bool) -> some View {
        let color = selected && reachability == .unknown ? Theme.onIndigoSecondary : reachability.tint
        let help = reachability == .offline
            ? (detail.map { L10n.t("Offline — %@", $0) } ?? L10n.t("Offline"))
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
                    .scaledFont(size: Theme.TextSize.caption, design: .monospaced)
                    .foregroundStyle(secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let ms = meta?.latencyMS, meta?.reachability == .online {
                    Text("\(ms)ms")
                        .scaledFont(size: Theme.TextSize.micro, weight: .medium, monospacedDigit: true)
                        .foregroundStyle(selected ? Theme.onIndigoSecondary : Color.secondary)
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
            Image(systemName: os.symbol).scaledFont(size: 8.5)
            Text(os.label).scaledFont(size: Theme.TextSize.micro, weight: .semibold).lineLimit(1)
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
            .scaledFont(size: Theme.TextSize.caption, weight: .bold)
            // Headers name the groups, so they carry information: secondary, not tertiary.
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
        content()
    }

    /// - Parameters:
    ///   - symbol: The row's glyph; a tag row passes nil and a colour `dot` instead.
    ///   - count: Pass when already known (tags); otherwise it is counted from the filter.
    ///   - shortcut: The ⌘-digit that selects this row, shown in the tooltip.
    private func item(_ label: String, _ symbol: String?, _ filter: SidebarFilter,
                      count: Int? = nil, dot: Color? = nil, shortcut: Int? = nil) -> some View {
        let selected = vm.filter == filter && vm.selectedServer == nil && !rss.isOpen
        let count = count ?? vm.count(for: filter)
        return Button {
            vm.closeServerBrowser()
            vm.filter = filter
        } label: {
            HStack(spacing: 9) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).scaledFont(size: Theme.TextSize.body)
                    } else if let dot {
                        Circle()
                            .fill(dot)
                            .frame(width: 8, height: 8)
                            // Keeps the dot visible on the selected row's accent fill.
                            .overlay(Circle().stroke(selected ? Theme.onAccent.opacity(0.7) : .clear, lineWidth: 1))
                    }
                }
                .frame(width: 16)
                .a11yDecorative()
                Text(label)
                    .scaledFont(size: Theme.TextSize.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                countPill(count, selected: selected, alert: filter == .failed && count > 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(selected ? Theme.accent : Color.clear)
            )
            .foregroundStyle(selected ? Theme.onAccent : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut.map { ShortcutHint.help(label, "⌘\($0)") } ?? label)
        .a11yGroup(label: label, value: L10n.t("%d downloads", count),
                   hint: L10n.t("Activate to filter the list."))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

extension SidebarView {
    /// A failed count is red while there is anything in it, so failures read from across the room.
    fileprivate func countPill(_ count: Int, selected: Bool, alert: Bool) -> some View {
        let fill: Color = alert ? Theme.red : (selected ? Theme.onAccent.opacity(0.25) : Theme.fillHover)
        return Text("\(count)")
            .scaledFont(size: Theme.TextSize.caption, weight: .semibold, monospacedDigit: true)
            .foregroundStyle(alert ? Theme.onRed : (selected ? Theme.onAccent : Color.primary))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(fill))
    }
}

/// Must stay its own view observing the center: nested observables do not propagate updates.
private struct MediaJobsSidebarGroup: View {

    @ObservedObject var center: MediaJobCenter

    var body: some View {
        // Kept while finished or failed cards remain, so a hidden dock can always be shown again.
        if !center.jobs.isEmpty {
            Text(L10n.t("Media").uppercased())
                .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .accessibilityLabel(L10n.t("Media"))
                .accessibilityAddTraits(.isHeader)
            Button {
                center.isDockHidden.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "waveform")
                        .scaledFont(size: Theme.TextSize.body)
                        .frame(width: 16)
                    Text(L10n.t("Converting"))
                        .scaledFont(size: Theme.TextSize.body)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: center.isDockHidden ? "eye.slash" : "eye")
                        .scaledFont(size: Theme.TextSize.caption)
                        .foregroundStyle(.secondary)
                        .a11yDecorative()
                    Text("\(center.liveCount)")
                        .scaledFont(size: Theme.TextSize.caption, weight: .semibold, monospacedDigit: true)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.18)))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(center.isDockHidden ? L10n.t("Show the conversion cards") : L10n.t("Hide the conversion cards"))
            .a11yGroup(label: L10n.t("Converting"),
                       value: center.liveCount == 1 ? L10n.t("%d media job in progress", center.liveCount)
                                     : L10n.t("%d media jobs in progress", center.liveCount),
                       hint: center.isDockHidden ? L10n.t("Activate to show the conversion cards.")
                                                 : L10n.t("Activate to hide the conversion cards."))
            .accessibilityAddTraits(.isButton)
        }
    }
}
