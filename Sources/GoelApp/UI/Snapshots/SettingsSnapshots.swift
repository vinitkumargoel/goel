#if DEBUG
import SwiftUI
import GoelCore

/// The Settings area's snapshots. Owned by the Settings area agent: add entries here only, named
/// `settings.<screen>`, e.g. `StudioSnapshotEntry("settings.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only settings.`
@MainActor
enum SettingsSnapshots {
    static var entries: [StudioSnapshotEntry] {
        []
    }
}
#endif
