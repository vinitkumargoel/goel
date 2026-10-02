#if DEBUG
import SwiftUI
import GoelCore

/// The AddFlow area's snapshots. Owned by the AddFlow area agent: add entries here only, named
/// `add.<screen>`, e.g. `StudioSnapshotEntry("add.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only add.`
@MainActor
enum AddFlowSnapshots {
    static var entries: [StudioSnapshotEntry] {
        []
    }
}
#endif
