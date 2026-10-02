#if DEBUG
import SwiftUI
import GoelCore

/// The SFTP area's snapshots. Owned by the SFTP area agent: add entries here only, named
/// `sftp.<screen>`, e.g. `StudioSnapshotEntry("sftp.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only sftp.`
@MainActor
enum SFTPSnapshots {
    static var entries: [StudioSnapshotEntry] {
        []
    }
}
#endif
