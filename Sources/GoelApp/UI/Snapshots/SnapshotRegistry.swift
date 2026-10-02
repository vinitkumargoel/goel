#if DEBUG
import SwiftUI
import GoelCore

/// One view the snapshot harness renders: `<name>-light.png` and `<name>-dark.png`.
///
///     StudioSnapshotEntry("downloads.board", width: 1280, height: 860) { context in
///         DownloadsBoard().studioSampleEnvironment(context.model)
///     }
///
/// Names are dotted and start with the area (`main.`, `downloads.`, `detail.`, `add.`,
/// `settings.`, `sftp.`, `windows.`, `ds.`) so `--only <prefix>` can pick an area.
struct StudioSnapshotEntry {
    let name: String
    let width: CGFloat
    /// nil sizes the height to the content's fitting height.
    let height: CGFloat?
    let render: @MainActor (StudioSnapshotContext) -> AnyView

    init<Content: View>(_ name: String, width: CGFloat, height: CGFloat? = nil,
                        @ViewBuilder content: @escaping @MainActor (StudioSnapshotContext) -> Content) {
        self.name = name
        self.width = width
        self.height = height
        self.render = { AnyView(content($0)) }
    }
}

/// What an entry's builder gets: the sample model and the pass being rendered.
@MainActor
struct StudioSnapshotContext {
    /// `.light` or `.dark`; the window's appearance is already set to match.
    let colorScheme: ColorScheme

    /// The shared sample `AppViewModel` (see `SampleData.swift`). Built on first use.
    var model: AppViewModel { StudioSampleData.makeViewModel() }

    /// The sample download with that name: `context.task(.ubuntu)`.
    func task(_ id: StudioSampleData.ID) -> DownloadTask { StudioSampleData.task(id) }
}

/// Every registered snapshot. Each area owns exactly one file and edits only that file.
@MainActor
enum StudioSnapshotRegistry {
    static var all: [StudioSnapshotEntry] {
        DesignSystemSnapshots.entries
            + MainWindowSnapshots.entries
            + DownloadsSnapshots.entries
            + DetailSnapshots.entries
            + AddFlowSnapshots.entries
            + SettingsSnapshots.entries
            + SFTPSnapshots.entries
            + WindowsSnapshots.entries
    }
}
#endif
