#if DEBUG
import SwiftUI
import GoelCore

/// The Detail area's snapshots. Owned by the Detail area agent: add entries here only, named
/// `detail.<screen>`, e.g. `StudioSnapshotEntry("detail.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only detail.`
@MainActor
enum DetailSnapshots {
    static var entries: [StudioSnapshotEntry] {
        []
    }
}
#endif
