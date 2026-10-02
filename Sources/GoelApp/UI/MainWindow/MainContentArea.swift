import SwiftUI
import GoelCore

/// What fills the window under the header: a server's files, the RSS reader, the restoring
/// placeholder, the first-run screen, or the downloads (Downloads area's `DownloadListView`).
/// The detail panel floats over the downloads as a trailing sheet, or docks underneath them —
/// the user's "Move Detail Panel" choice, or forced while the window is too narrow.
struct MainContentArea: View {
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject private var rss = RSSReaderModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mainWindowPreview) private var preview

    @Binding var omniboxText: String
    var omniboxFocus: FocusState<Bool>.Binding

    /// The bottom detail panel's height, dragged by its top edge.
    @AppStorage("detailBottomPanelHeight") private var bottomPanelHeight: Double = DetailPanelHeight.standard
    /// The height drawn mid-drag, persisted only when the drag ends.
    @State private var liveBottomPanelHeight: Double?
    /// The content's height, so the panel can't squeeze the list out of a short window.
    @State private var columnHeight: Double = 0

    static let detailSheetWidth: CGFloat = 372

    /// With nothing selected the panel shows the queue overview, so it follows the toggle alone.
    /// It inspects downloads, so it stays out of a server browser, the RSS reader and the first run.
    private var showsDownloads: Bool {
        vm.selectedServer == nil && !rss.isOpen && !vm.tasks.isEmpty
    }

    private var floatsDetail: Bool {
        vm.detailPanelVisible && showsDownloads && vm.effectiveDetailPanelPosition == .right
    }

    private var docksDetail: Bool {
        vm.detailPanelVisible && showsDownloads && vm.effectiveDetailPanelPosition == .bottom
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomDock
        }
        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { columnHeight = $0 }
        .overlay(alignment: .topTrailing) {
            if floatsDetail {
                detailSheet
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(animation, value: floatsDetail)
        .animation(animation, value: docksDetail)
    }

    @ViewBuilder
    private var content: some View {
        if let server = vm.server(vm.selectedServer) {
            // The `.id` must include the generation, or Reconnect reuses the dead client.
            SFTPBrowserView(connection: server, client: vm.sftpClient(for: server))
                .id("\(server.id)-\(vm.browserGeneration)")
        } else if rss.isOpen {
            RSSReaderView()
        } else if vm.tasks.isEmpty && vm.isRestoring {
            // The queue loads asynchronously; the first-run screen would flash here.
            RestoringPlaceholder()
        } else if vm.tasks.isEmpty {
            DownloadsEmptyState(omniboxText: $omniboxText, omniboxFocus: omniboxFocus)
        } else {
            DownloadListView()
        }
    }

    /// Studio's floating sheet: over the board, trailing, so the board never narrows.
    private var detailSheet: some View {
        DetailPanelView()
            .frame(width: Self.detailSheetWidth)
            .frame(maxHeight: .infinity)
            .studioSurface(.sheet, radius: Studio.Radius.sheet, elevation: .floating)
            .padding(.top, Studio.Space.xs)
            .padding(.trailing, Studio.Space.ml)
            .padding(.bottom, Studio.Space.ml)
    }

    @ViewBuilder
    private var bottomDock: some View {
        if docksDetail {
            DetailPanelResizeHandle(storedHeight: $bottomPanelHeight,
                                    liveHeight: $liveBottomPanelHeight,
                                    displayedHeight: displayedBottomPanelHeight)
            DetailBottomPanel()
                .frame(height: displayedBottomPanelHeight)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var displayedBottomPanelHeight: Double {
        DetailPanelHeight.fitted(liveBottomPanelHeight ?? bottomPanelHeight, available: columnHeight)
    }

    private var animation: Animation? {
        reduceMotion || preview != nil ? nil : Studio.Motion.spring
    }
}

/// Ghost cards in the shape of the queue while it restores from disk.
struct RestoringPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.cardGap) {
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: Studio.Space.m) {
                    StudioFileArtwork(kind: .other, size: .s, isGhost: true)
                    VStack(alignment: .leading, spacing: Studio.Space.xs) {
                        Capsule().fill(Studio.Palette.segment)
                            .frame(width: [220, 180, 260, 200, 150][index], height: 10)
                        Capsule().fill(Studio.Palette.segment.opacity(0.7))
                            .frame(width: [120, 90, 140, 110, 80][index], height: 8)
                    }
                    Spacer(minLength: 0)
                    Capsule().fill(Studio.Palette.segment).frame(width: 52, height: 8)
                }
                .padding(.horizontal, Studio.Space.m)
                .frame(height: 58)
                .frame(maxWidth: 820)
                .studioSurface(.card, radius: Studio.Radius.compactCard, elevation: .raised)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.gutter)
        .padding(.top, Studio.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Loading downloads"))
    }
}
