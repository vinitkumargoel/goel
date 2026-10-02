#if DEBUG
import SwiftUI
import GoelCore

/// The Windows area's snapshots. Owned by the Windows area agent: add entries here only, named
/// `windows.<screen>`, e.g. `StudioSnapshotEntry("windows.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only windows.`
@MainActor
enum WindowsSnapshots {
    static var entries: [StudioSnapshotEntry] {
        []
    }
}
#endif
