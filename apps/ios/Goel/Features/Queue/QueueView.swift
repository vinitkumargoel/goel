import SwiftUI

/// The app's home — `visual.html` frame 1, "Downloads — the queue".
///
/// ```css
/// .largetitle { font-size: 34px; padding: 0 16px 6px; }
/// .seg        { margin: 4px 16px 14px; }
/// .row        { border-bottom: .5px solid var(--ios-sep); }
/// ```
///
/// The screen owns three things and nothing else: which slice of the queue is on show, what a
/// tap means, and where a row's actions go. All state lives in ``AppModel`` so a deep link from
/// a widget or a Live Activity lands on the same navigation stack the user is already looking at.
public struct QueueView: View {

    /// Values off `visual.html` that ``Theme/Metric`` does not carry yet.
    private enum Local {
        /// `.seg { margin-top: 4px }`.
        static let filterTopInset: CGFloat = 4
        /// `.seg { margin-bottom: 14px }`.
        static let filterBottomInset: CGFloat = 14
        /// How often the Active tab re-evaluates its wall-clock grace filter. The grace is ten
        /// minutes, so a coarse tick is plenty; `TimelineView` pauses it while the tab is hidden.
        static let gracePollInterval: TimeInterval = 30
    }

    /// The mockup's three-way segmented control.
    ///
    /// Between them `.active` and `.done` cover the queue exactly once: a failure is *not* done,
    /// so it stays in Active where it can still be retried instead of disappearing into All.
    private enum Filter: String, CaseIterable, Identifiable {
        case active, all, done

        var id: Self { self }

        var title: String {
            switch self {
            case .active: "Active"
            case .all: "All"
            case .done: "Done"
            }
        }

        /// How long a finished transfer lingers in Active. The mockup shows a verified download
        /// sitting under the four in-flight ones, and it is right to: a file that landed thirty
        /// seconds ago vanishing the instant it completes reads as "where did it go?", not as
        /// tidiness. After the grace period it lives in Done.
        static let completedGrace: TimeInterval = 10 * 60

        func matches(_ download: Download, now: Date = Date()) -> Bool {
            switch self {
            case .active:
                guard download.status == .completed else { return true }
                guard let at = download.completedAt else { return false }
                return now.timeIntervalSince(at) <= Self.completedGrace
            case .all: return true
            case .done: return download.status == .completed
            }
        }

        var emptyTitle: String {
            switch self {
            case .active: "Nothing downloading"
            case .all: "Your queue is empty"
            case .done: "Nothing finished yet"
            }
        }

        var emptySymbol: String {
            switch self {
            case .active: "arrow.down.circle"
            case .all: "tray"
            case .done: "checkmark.circle"
            }
        }

        var emptyMessage: String {
            switch self {
            case .active:
                "Paste a link and Goel° pulls it down over several connections at once, picks up where it left off after a drop, and verifies it when it lands."
            case .all:
                "Nothing here yet. Add a link and it will appear at the top of this list."
            case .done:
                "Finished transfers collect here with their checksum. Nothing has completed on this device yet."
            }
        }
    }

    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .active

    public init() {}

    public var body: some View {
        @Bindable var app = app

        NavigationStack(path: $app.queuePath) {
            VStack(spacing: 0) {
                filterPicker
                queue
            }
            .background(Theme.Color.ground.ignoresSafeArea())
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.isAddSheetPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a download")
                }
            }
            // T08 owns this screen; the queue only knows how to get there.
            .navigationDestination(for: UUID.self) { id in
                DetailView(downloadID: id)
            }
        }
        // T09 owns the sheet.
        .sheet(isPresented: $app.isAddSheetPresented) {
            AddSheet()
        }
    }

    // MARK: - Filter

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(Filter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        // The root `.tint` is ember, which would paint the selected segment orange. The mockup's
        // selected pill is `--ios-elev-3` grey — the ember in this screen belongs to the speed
        // reading and the toolbar, not to a control that is merely switched on.
        .tint(Theme.Color.elev3)
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, Local.filterTopInset)
        .padding(.bottom, Local.filterBottomInset)
        .accessibilityLabel("Show")
    }

    // MARK: - List

    private func visible(now: Date) -> [Download] {
        app.store.downloads.filter { filter.matches($0, now: now) }
    }

    @ViewBuilder
    private var queue: some View {
        // The Active filter ages a completed download out on a ten-minute wall-clock grace, but
        // nothing mutates the store when that timer merely elapses — so without a clock the row
        // would linger in Active until an unrelated change forced a re-render. TimelineView
        // re-evaluates the filter on a periodic tick (and pauses while this tab is off-screen).
        TimelineView(.periodic(from: .now, by: Local.gracePollInterval)) { context in
            queueList(rows: visible(now: context.date))
        }
    }

    @ViewBuilder
    private func queueList(rows: [Download]) -> some View {
        if rows.isEmpty {
            emptyState
        } else {
            List {
                ForEach(rows) { download in
                    DownloadRow(download: download) {
                        primaryAction(for: download)
                    }
                    .contentShape(.rect)
                    .onTapGesture { open(download) }
                    // Horizontal gutter lives here rather than on the row so the row stays
                    // reusable inside a grouped list on the Library screen. The separator
                    // follows the content's leading edge, which puts it at the mockup's 16 pt.
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: Theme.Metric.gutter,
                        bottom: 0,
                        trailing: Theme.Metric.gutter
                    ))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.Color.separator)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        leadingAction(for: download)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            app.remove(download.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets where rows.indices.contains(index) {
                        app.remove(rows[index].id)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.Color.ground)
        }
    }

    @ViewBuilder
    private func leadingAction(for download: Download) -> some View {
        switch download.status {
        case .completed:
            EmptyView()
        case .failed, .waitingForWiFi:
            Button {
                app.retry(download.id)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .tint(Theme.Color.ember)
        case .paused, .queued:
            Button {
                app.togglePause(download.id)
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .tint(Theme.Color.ember)
        case .downloading, .probing, .verifying:
            Button {
                app.togglePause(download.id)
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .tint(Theme.Color.ember)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label(filter.emptyTitle, systemImage: filter.emptySymbol)
        } description: {
            Text(filter.emptyMessage)
        } actions: {
            Button {
                app.isAddSheetPresented = true
            } label: {
                Text("Add a download")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Color.ember)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Intent

    /// Tapping the row body. A finished video opens the player (T10 presents it from
    /// ``AppModel/playerID``); everything else opens the detail screen.
    private func open(_ download: Download) {
        if download.status == .completed, QueueMedia.isPlayableVideo(download) {
            app.playerID = download.id
            return
        }
        app.queuePath.append(download.id)
    }

    /// Tapping the trailing circle. Mirrors the glyph ``DownloadRow`` draws, so ▶ never pauses
    /// anything: a deferred transfer starts, a failed one retries, a playable video plays.
    private func primaryAction(for download: Download) {
        switch download.status {
        case .completed:
            open(download)
        case .failed, .waitingForWiFi:
            app.retry(download.id)
        case .downloading, .probing, .verifying, .paused, .queued:
            if QueueMedia.isPlayableNow(download) {
                app.playerID = download.id
            } else {
                app.togglePause(download.id)
            }
        }
    }
}

// MARK: - Previews

/// A composition root for previews: the frozen fixture engine plus a throwaway store, so a
/// preview can never read — or overwrite — the App Group queue.
@MainActor
func goelQueuePreviewModel(
    _ downloads: [Download] = PreviewTransferEngine.fixtures()
) -> AppModel {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("goel-preview-\(UUID().uuidString).json")
    let store = DownloadStore(persistenceURL: url)
    store.replaceAll(downloads)
    return AppModel(engine: PreviewTransferEngine.makeStatic(), store: store)
}

#Preview("Queue · dark") {
    QueueView()
        .environment(goelQueuePreviewModel())
        .tint(Theme.Color.ember)
        .preferredColorScheme(.dark)
}

#Preview("Queue · light") {
    QueueView()
        .environment(goelQueuePreviewModel())
        .tint(Theme.Color.ember)
        .preferredColorScheme(.light)
}

#Preview("Queue · empty") {
    QueueView()
        .environment(goelQueuePreviewModel([]))
        .tint(Theme.Color.ember)
        .preferredColorScheme(.dark)
}

#Preview("Queue · Accessibility XXL") {
    QueueView()
        .environment(goelQueuePreviewModel())
        .tint(Theme.Color.ember)
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}
