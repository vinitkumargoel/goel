import Foundation

/// Factory for ``SFTPClient`` construction shared by the queued ``SFTPEngine``
/// and the app browser transfer path. One place for credential resolution
/// (Keychain / inline URL userinfo / explicit password) and host-key store wiring.
///
/// Path arithmetic stays on ``SFTPBrowserPaths``; host-key pin/learn stays inside
/// ``SFTPClient`` / ``HostKeyStore``.
public enum SFTPSession {

    /// Build a client for a saved connection. When `password` is nil the secret
    /// is loaded from `store` (Keychain); pass an explicit value (including `""`)
    /// to skip the lookup — used by the connection editor's "Test" button.
    public static func client(
        for connection: SFTPConnection,
        password: String? = nil,
        store: SFTPConnectionStore = .shared,
        hostKeys: HostKeyStore = .shared
    ) -> SFTPClient? {
        let resolved = password ?? store.password(for: connection)
        guard let target = SFTPTarget(connection: connection, password: resolved) else {
            return nil
        }
        return SFTPClient(target: target, hostKeys: hostKeys)
    }

    /// Wrap an already-resolved target (engine URL path, tests).
    public static func client(
        for target: SFTPTarget,
        hostKeys: HostKeyStore = .shared
    ) -> SFTPClient {
        SFTPClient(target: target, hostKeys: hostKeys)
    }

    /// Build a client from an `sftp://` URL. Password comes from inline userinfo
    /// or the connection store (see ``SFTPTarget/init(url:)``). Nil when the URL
    /// lacks a host/user.
    public static func client(
        for url: URL,
        hostKeys: HostKeyStore = .shared
    ) -> SFTPClient? {
        guard let target = SFTPTarget(url: url) else { return nil }
        return SFTPClient(target: target, hostKeys: hostKeys)
    }
}
