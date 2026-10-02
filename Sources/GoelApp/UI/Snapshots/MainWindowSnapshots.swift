#if DEBUG
import SwiftUI
import GoelCore

/// The MainWindow area's snapshots. Owned by the MainWindow area agent: add entries here only, named
/// `main.<screen>`, e.g. `StudioSnapshotEntry("main.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only main.`
@MainActor
enum MainWindowSnapshots {
    static var entries: [StudioSnapshotEntry] {
        []
    }
}
#endif
