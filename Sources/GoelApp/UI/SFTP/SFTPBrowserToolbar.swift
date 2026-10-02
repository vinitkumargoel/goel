import SwiftUI
import AppKit
import GoelCore

/// The browser's toolbar row (`.tbar.line`): back to Downloads, history and parent, the path,
/// the filter, new folder and refresh, Upload and Download, then the layout and view options.
extension SFTPBrowserView {

    var toolbar: some View {
        HStack(spacing: Studio.Space.sm) {
            // A labelled chevron: the old door-and-arrow glyph read as "disconnect".
            Button(L10n.t("Downloads"), systemImage: "chevron.left") { vm.closeServerBrowser() }
                .buttonStyle(.studio(.ghost, size: .small))
                .help(L10n.t("Back to downloads"))
                .accessibilityLabel(L10n.t("Back to downloads"))
                .fixedSize()
            navigationButtons
            breadcrumbBar
            Spacer(minLength: Studio.Space.xs)
            filterField
            HStack(spacing: Studio.Space.xxs) {
                StudioIconButton("folder.badge.plus", label: L10n.t("New folder"), size: .small,
                                 shortcutHint: "⇧⌘N") { requestNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                refreshControl
            }
            transferButtons
            StudioSegmentedControl(
                selection: layoutBinding,
                segments: [
                    StudioSegment(false, title: "", symbol: "list.bullet", accessibilityLabel: L10n.t("List")),
                    StudioSegment(true, title: "", symbol: "square.grid.2x2", accessibilityLabel: L10n.t("Grid")),
                ],
                size: .small,
                accessibilityLabel: L10n.t("View style"))
            viewMenuButton
        }
        .padding(.horizontal, Studio.Space.l)
        .frame(height: 50)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
        .background(Studio.Palette.well)
        .overlay(alignment: .bottom) { StudioDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Server browser toolbar"))
    }

    private var navigationButtons: some View {
        HStack(spacing: Studio.Space.hair) {
            StudioIconButton("chevron.backward", label: L10n.t("Back"), size: .small, shortcutHint: "⌘[") {
                Task { await model.goBack() }
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            StudioIconButton("chevron.forward", label: L10n.t("Forward"), size: .small, shortcutHint: "⌘]") {
                Task { await model.goForward() }
            }
            .disabled(!model.canGoForward)
            .keyboardShortcut("]", modifiers: .command)
            StudioIconButton("chevron.up", label: L10n.t("Parent folder"), size: .small, shortcutHint: "⌘↑") {
                Task { await model.goUp() }
            }
            .disabled(model.isAtRoot)
            .keyboardShortcut(.upArrow, modifiers: .command)
        }
    }

    @ViewBuilder
    private var refreshControl: some View {
        if model.isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(Studio.Palette.accent)
                .frame(width: 26, height: 26)
                .accessibilityLabel(L10n.t("Loading folder"))
        } else {
            StudioIconButton("arrow.clockwise", label: L10n.t("Refresh"), size: .small, shortcutHint: "⌘R") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: - Path

    /// The server chip, then the path. When it doesn't fit, the leading folders fold into a
    /// "…" menu one at a time, so the current folder always shows.
    private var breadcrumbBar: some View {
        let crumbs = SFTPBrowserListing.breadcrumbs(for: model.path)
        return ViewThatFits(in: .horizontal) {
            ForEach(0..<crumbs.count, id: \.self) { hidden in
                crumbRow(crumbs, hidden: hidden, showsServer: true)
            }
            crumbRow(crumbs, hidden: crumbs.count - 1, showsServer: false)
        }
        .frame(minWidth: 110, maxWidth: 460, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Folder path"))
    }

    private func crumbRow(_ crumbs: [SFTPBrowserListing.Crumb], hidden: Int, showsServer: Bool) -> some View {
        HStack(spacing: Studio.Space.xs) {
            if showsServer {
                StudioChip(model.connection.label, symbol: "server.rack", size: .small)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
            }
            if hidden > 0 {
                if showsServer { crumbChevron }
                Menu {
                    ForEach(Array(crumbs.prefix(hidden).enumerated()), id: \.offset) { _, crumb in
                        Button(crumb.label) { Task { await model.go(toPath: crumb.path) } }
                    }
                } label: {
                    Text(verbatim: "…").studioFont(.small.weight(700)).foregroundStyle(Studio.Palette.ink2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L10n.t("Folder path"))
            }
            ForEach(Array(crumbs.enumerated()).dropFirst(hidden), id: \.offset) { index, crumb in
                if index > 0 || showsServer { crumbChevron }
                crumbButton(crumb, isLast: index == crumbs.count - 1)
            }
        }
        .padding(.vertical, Studio.Space.hair)
    }

    private var crumbChevron: some View {
        Image(systemName: "chevron.right")
            .font(StudioFonts.font(.ui, size: 9, weight: 700))
            .foregroundStyle(Studio.Palette.ink3)
            .a11yDecorative()
    }

    private func crumbButton(_ crumb: SFTPBrowserListing.Crumb, isLast: Bool) -> some View {
        Button {
            if !isLast { Task { await model.go(toPath: crumb.path) } }
        } label: {
            Text(crumb.label)
                .studioFont(isLast ? .small.weight(700) : .small)
                .foregroundStyle(isLast ? Studio.Palette.ink : Studio.Palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
        }
        .buttonStyle(SFTPCrumbButtonStyle())
        .disabled(isLast)
        .accessibilityLabel(isLast ? L10n.t("Current folder, %@", crumb.label) : L10n.t("Go to %@", crumb.label))
    }

    // MARK: - Filter

    private var filterField: some View {
        HStack(spacing: Studio.Space.xs) {
            StudioSearchField(text: $searchText,
                              placeholder: toolbarWidth < 1040 ? L10n.t("Filter") : L10n.t("Filter this folder"),
                              size: .small, onSubmit: openSoleSearchResult)
                .frame(width: toolbarWidth < 1040 ? 130 : 180)
                .accessibilityLabel(L10n.t("Filter this folder"))
                .accessibilityHint(L10n.t("Press return to open the only match."))
            if isFiltering {
                Text(verbatim: "\(visibleEntries.count)")
                    .studioFont(Studio.TextStyle.monoSmall.weight(600))
                    .foregroundStyle(Studio.Palette.ink2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, Studio.Space.hair)
                    .background(Studio.Palette.segment, in: Capsule())
                    .fixedSize()
                    .accessibilityLabel(L10n.t("%d matches", visibleEntries.count))
            }
        }
    }

    // MARK: - Upload / Download

    private var transferButtons: some View {
        let targets = selectedEntries
        let labelled = toolbarWidth >= 1040
        return HStack(spacing: labelled ? Studio.Space.xs : Studio.Space.xxs) {
            uploadButton(labelled: labelled)
            downloadButton(targets, labelled: labelled)
        }
    }

    private func uploadButton(labelled: Bool) -> some View {
        Button { chooseUploadItems() } label: {
            if labelled {
                Label(L10n.t("Upload"), systemImage: "arrow.up.doc")
            } else {
                Image(systemName: "arrow.up.doc")
            }
        }
        .buttonStyle(.studio(.secondary, size: .small))
        .fixedSize()
        .help(L10n.t("Upload files or folders"))
        .accessibilityLabel(L10n.t("Upload files or folders"))
    }

    /// Downloads the selection into the Default-folder rule's folder; ⌥-click asks where.
    private func downloadButton(_ targets: [SFTPEntry], labelled: Bool) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) { chooseDownloadFolder(forAll: targets) }
            else { downloadTargets(targets) }
        } label: {
            if labelled {
                Label(targets.count > 1 ? L10n.t("Download %d Items", targets.count) : L10n.t("Download"),
                      systemImage: "arrow.down.doc")
            } else {
                Image(systemName: "arrow.down.doc")
            }
        }
        .buttonStyle(.studio(.primary, size: .small))
        .fixedSize()
        .disabled(targets.isEmpty)
        .help(L10n.t("Download the selection to your default folder — Option-click to choose where"))
        .accessibilityLabel(L10n.t("Download selection"))
    }

    // MARK: - View options

    private var viewMenuButton: some View {
        StudioIconButton("line.3.horizontal.decrease", label: L10n.t("Sort & display options"),
                         size: .small, isOn: viewMenuOpen) {
            viewMenuOpen.toggle()
        }
        .accessibilityLabel(L10n.t("Sort and display options"))
        .accessibilityValue("\(isGrid ? L10n.t("Grid") : L10n.t("List")), \(sortKey.title), "
                            + "\(sortAscending ? L10n.t("ascending") : L10n.t("descending"))")
        .popover(isPresented: $viewMenuOpen, arrowEdge: .bottom) {
            SFTPViewOptionsMenu(isGrid: layoutBinding, sortKey: sortKey, sortAscending: sortAscending,
                                showHidden: $showHidden, onSort: setSort,
                                onClose: { viewMenuOpen = false })
        }
    }

    func setSort(_ key: SFTPBrowserSortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
    }

    // MARK: - Connection line

    /// "Connected · 12 ms" and who is logged in, above the files (the mockup's status line).
    var connectionLine: some View {
        let meta = vm.serverMeta[model.connection.id]
        let reach = meta?.reachability ?? .unknown
        return HStack(spacing: Studio.Space.sm) {
            StudioPill(reachabilityTitle(reach, latency: meta?.latencyMS), tone: reachabilityTone(reach))
                .help(reach == .offline ? (meta?.offlineDetail ?? L10n.t("Offline")) : L10n.t(reach.help))
            Text(L10n.t("%1$@ · %2$@", model.connection.credentialKey, SFTPAuthLabel.label(for: model.connection)))
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
            if let os = meta?.os {
                Text(os.label)
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.gutter)
        .padding(.top, Studio.Space.ml)
        .padding(.bottom, Studio.Space.sm)
        .accessibilityElement(children: .combine)
    }

    private func reachabilityTitle(_ reach: ServerReachability, latency: Int?) -> String {
        switch reach {
        case .online:
            return latency.map { L10n.t("Connected · %d ms", $0) } ?? L10n.t("Connected")
        case .offline: return L10n.t("Offline")
        case .unknown: return L10n.t("Checking…")
        }
    }

    private func reachabilityTone(_ reach: ServerReachability) -> StudioTone {
        switch reach {
        case .online: return .good
        case .offline: return .bad
        case .unknown: return .neutral
        }
    }
}

/// How a connection logs in, in two words.
enum SFTPAuthLabel {
    static func label(for connection: SFTPConnection) -> String {
        if connection.useAgent { return L10n.t("SSH agent") }
        if connection.privateKeyPath?.isEmpty == false { return L10n.t("SSH key") }
        return L10n.t("Password")
    }
}

/// A path crumb: plain text that gains a segment fill on hover.
private struct SFTPCrumbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SFTPCrumbBody(configuration: configuration)
    }
}

private struct SFTPCrumbBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.badge, style: .continuous)
        configuration.label
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(shape.fill(hovered && isEnabled ? Studio.Palette.segment : .clear))
            .studioFocusRing(isFocused, shape: shape)
            .onHover { hovered = $0 }
    }
}

/// The View options popover: layout, sort order and hidden files, as Finder's View menu has them.
struct SFTPViewOptionsMenu: View {
    @Binding var isGrid: Bool
    let sortKey: SFTPBrowserSortKey
    let sortAscending: Bool
    @Binding var showHidden: Bool
    let onSort: (SFTPBrowserSortKey) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.hair) {
            section(L10n.t("View style"))
            StudioMenuRow(symbol: "list.bullet", title: L10n.t("List"), isChecked: !isGrid) {
                isGrid = false; onClose()
            }
            StudioMenuRow(symbol: "square.grid.2x2", title: L10n.t("Grid"), isChecked: isGrid) {
                isGrid = true; onClose()
            }
            StudioDivider().padding(.vertical, Studio.Space.xxs)
            section(L10n.t("Sort By"))
            ForEach(SFTPBrowserSortKey.allCases) { key in
                StudioMenuRow(symbol: nil, title: key.title,
                              shortcut: sortKey == key ? (sortAscending ? "↑" : "↓") : nil,
                              isChecked: sortKey == key) { onSort(key) }
            }
            StudioDivider().padding(.vertical, Studio.Space.xxs)
            StudioMenuRow(symbol: showHidden ? "eye.slash" : "eye",
                          title: showHidden ? L10n.t("Hide Hidden Files") : L10n.t("Show Hidden Files"),
                          isChecked: false) {
                showHidden.toggle(); onClose()
            }
        }
        .padding(Studio.Space.s)
        .frame(width: 230, alignment: .leading)
        .background(Studio.Palette.cardRaised)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .studioFont(.eyebrow)
            .foregroundStyle(Studio.Palette.ink3)
            .padding(.horizontal, Studio.Space.sm)
            .padding(.top, Studio.Space.xxs)
            .padding(.bottom, Studio.Space.hair)
            .accessibilityAddTraits(.isHeader)
    }
}
