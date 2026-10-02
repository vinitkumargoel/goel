#if DEBUG
import SwiftUI
import GoelCore

/// The Downloads area's snapshots. Owned by the Downloads area agent: add entries here only, named
/// `downloads.<screen>`, e.g. `StudioSnapshotEntry("downloads.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only downloads.`
@MainActor
enum DownloadsSnapshots {
    static var entries: [StudioSnapshotEntry] {
        []
    }
}
#endif
