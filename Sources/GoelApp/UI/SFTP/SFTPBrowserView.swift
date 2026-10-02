import SwiftUI
import AppKit
import GoelCore

/// A server's files, hosted by the main window's content area when a server is picked in the rail.
/// Toolbar (navigation, path, filter, new folder, refresh, upload, download, view options), the
/// folder as a list or a grid of tiles, an info side sheet, this server's transfers and a footer.
///
/// The parts live in extensions: `+Toolbar`, `+Content`, `+Menus`, `+Actions`, `+Keyboard`,
/// `+Chrome`. State is internal (not `private`) so those files can reach it.
struct SFTPBrowserView: View {
    @EnvironmentObject var vm: AppViewModel
    /// Observed so this server's transfer list redraws; read through `vm.sftpTransfers(for:)`.
    @EnvironmentObject var sftpStore: SFTPTransferStore
    @StateObject var model: SFTPBrowserModel

    let connection: SFTPConnection
    let client: SFTPClient?
    /// A snapshot: the model is seeded, so nothing is listed, restored or probed.
    let isSnapshot: Bool
    /// A snapshot's throughput samples for the transfers dock; the app reads the telemetry store.
    var transferHistory: [UUID: [Double]]?

    @State var dropTargeted = false
    @State var nameRequest: SFTPNameRequest?
    @State var errorExpanded = false

    @State var hoveredEntry: SFTPEntry.ID?
    @State var folderDropTarget: SFTPEntry.ID?
    @AppStorage("sftp.browser.gridView") var storedGrid = false
    /// Set only by a snapshot, so it can show either layout without writing the preference.
    @State var gridOverride: Bool?
    @State var searchText = ""
    @State var selection: Set<SFTPEntry.ID> = []
    @State var cursor: SFTPEntry.ID?
    @FocusState var listFocused: Bool
    @AppStorage("sftp.browser.sortKey") var sortKey: SFTPBrowserSortKey = .name
    @AppStorage("sftp.browser.sortAsc") var sortAscending = true
    @AppStorage("sftp.browser.showHidden") var showHidden = false
    @State var viewMenuOpen = false
    /// The toolbar folds its labels and narrows the filter below a width, so the path stays legible.
    @State var toolbarWidth: CGFloat = 1200

    @State var info = SFTPInfoState()
    @State var infoSizeTask: Task<Void, Never>?
    @State var infoSizeCancel: CancelFlag?

    @State var typeSelectBuffer = ""
    @State var typeSelectAt = Date.distantPast
    static let typeSelectWindow: TimeInterval = 1.0
    @State var volumeSpace: SFTPVolumeSpace?

    /// Row frames live in a plain box, not `@State` values: they change on every
    /// scroll tick and only the marquee drag ever reads them.
    final class EntryFrames { var frames: [SFTPEntry.ID: CGRect] = [:] }
    @State var entryFrames = EntryFrames()
    @State var marqueeRect: CGRect?
    @State var marqueeBase: Set<SFTPEntry.ID>?
    static let listSpace = "sftp.entryList"

    init(connection: SFTPConnection, client: SFTPClient?) {
        self.connection = connection
        self.client = client
        self.isSnapshot = false
        _model = StateObject(wrappedValue: SFTPBrowserModel(connection: connection, client: client))
    }

    var body: some View {
        withNameSheet(withLifecycle(mainStack))
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            toolbar
            banners
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    connectionLine
                    entryArea
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let entry = info.entry {
                    infoPanel(entry)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
            transferFooter
            statusFooter
        }
        .background(Studio.Palette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Files on %@", model.connection.label))
    }

    // MARK: - Derived

    var isGrid: Bool { gridOverride ?? storedGrid }

    var layoutBinding: Binding<Bool> {
        Binding(get: { isGrid }, set: { gridOverride = nil; storedGrid = $0 })
    }

    var visibleEntries: [SFTPEntry] {
        SFTPBrowserListing.visible(model.entries, showHidden: showHidden, filter: searchText,
                                   sortKey: sortKey, ascending: sortAscending)
    }

    var selectedEntries: [SFTPEntry] { visibleEntries.filter { selection.contains($0.id) } }

    var myTransfers: [SFTPTransfer] { vm.sftpTransfers(for: model.connection.id) }

    var isFiltering: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Lifecycle

    private func withLifecycle<V: View>(_ content: V) -> some View {
        content
            .task(id: model.connection.id) {
                guard !isSnapshot else { return }
                await model.restore()
                await consumeNavigationRequest(vm.sftpBrowserNavigation)
                // Reuses this authenticated session; never opens one to an un-browsed server.
                vm.detectServerOSIfNeeded(connection, client: client)
            }
            // The @StateObject model outlives the parent's re-render; without this it keeps the pre-edit login.
            .onChange(of: connection) {
                model.update(connection: connection, client: client)
                Task { await model.refresh() }
            }
            .onChange(of: vm.sftpMutationTick) {
                Task {
                    await model.refresh()
                    volumeSpace = await model.volumeSpace()
                }
            }
            .onChange(of: vm.sftpBrowserNavigation) { _, request in
                Task { await consumeNavigationRequest(request) }
            }
            // SFTPEntry ids are just names: a same-named entry must not inherit the old highlight.
            .onChange(of: model.path) { resetForNewPath() }
            .onChange(of: model.error) { _, _ in errorExpanded = false }
            // With the info sheet open, picking another item shows that item, as Finder's inspector does.
            .onChange(of: selection) { _, next in followSelectionWithInfo(next) }
            .task(id: model.path) {
                guard !isSnapshot else { return }
                volumeSpace = await model.volumeSpace()
            }
    }

    private func resetForNewPath() {
        hoveredEntry = nil; folderDropTarget = nil; searchText = ""
        selection.removeAll(); cursor = nil
        typeSelectBuffer = ""; typeSelectAt = .distantPast
        closeInfo()
    }

    func consumeNavigationRequest(_ request: SFTPBrowserNavigationRequest?) async {
        guard let request, request.connectionID == model.connection.id else { return }
        _ = await model.go(toPath: request.path)
        vm.acknowledgeSFTPBrowserNavigation(request.id)
    }

    private func withNameSheet<V: View>(_ content: V) -> some View {
        content.sheet(item: $nameRequest) { request in
            SFTPNameSheet(request: request,
                          onCancel: { nameRequest = nil },
                          onCommit: { name in
                              nameRequest = nil
                              commitName(request, name)
                          })
        }
    }
}

/// What the info side sheet is showing. The folder walk's task lives beside it in the view.
struct SFTPInfoState {
    var entry: SFTPEntry?
    var info: SFTPEntryInfo?
    var folderSize: Int64?
    var sizeError: String?
    var isSizing = false
}

#if DEBUG
/// What a snapshot seeds the browser with: no network, no stored preferences touched.
struct SFTPBrowserPreview {
    var path: String
    var entries: [SFTPEntry]
    var isGrid = false
    var selection: Set<SFTPEntry.ID> = []
    var searchText = ""
    var error: String?
    var deleteProgress: String?
    var volumeSpace: SFTPVolumeSpace?
    var info: SFTPInfoState?
    var dropTargeted = false
    var transferHistory: [UUID: [Double]]?
}

extension SFTPBrowserView {
    init(connection: SFTPConnection, preview: SFTPBrowserPreview) {
        self.connection = connection
        self.client = nil
        self.isSnapshot = true
        let model = SFTPBrowserModel(connection: connection, client: nil)
        model.installSnapshot(path: preview.path, entries: preview.entries, error: preview.error,
                              deleteProgress: preview.deleteProgress)
        _model = StateObject(wrappedValue: model)
        _gridOverride = State(initialValue: preview.isGrid)
        _selection = State(initialValue: preview.selection)
        _cursor = State(initialValue: preview.selection.first)
        _searchText = State(initialValue: preview.searchText)
        _volumeSpace = State(initialValue: preview.volumeSpace)
        _info = State(initialValue: preview.info ?? SFTPInfoState())
        _dropTargeted = State(initialValue: preview.dropTargeted)
        self.transferHistory = preview.transferHistory
    }
}
#endif
