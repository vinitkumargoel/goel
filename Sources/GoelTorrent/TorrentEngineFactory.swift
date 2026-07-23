import Foundation
import GoelContracts
import GoelCore

/// The single public entry point of `GoelTorrent`: builds the production
/// libtorrent-backed engine, configured from `settings`.
///
/// The desktop app and the Linux daemon pass this as ``DownloadManager``'s
/// `makeTorrentEngine` closure, so the concrete ``TorrentEngine`` — and its
/// libtorrent linkage — stays entirely inside this module. `GoelCore` and the
/// iOS build that excludes `GoelTorrent` never name it.
public func makeTorrentEngine(settings: AppSettings) -> any DownloadEngine {
    TorrentEngine(
        profile: settings.effectiveProfile,
        config: TorrentEngine.SessionConfig(
            enableDHT: settings.btEnableDHT,
            enableLSD: settings.btEnableLPD,
            enableUTP: settings.btEnableUTP,
            encryptionMode: settings.btEncryptionMode
        )
    )
}
