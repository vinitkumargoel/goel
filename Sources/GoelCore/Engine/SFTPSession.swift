import Foundation

/// ``SFTPClient`` factory shared by ``SFTPEngine`` and the browser transfer path: one place for
/// credential resolution (Keychain / inline URL userinfo / explicit password) and host-key wiring.
public enum SFTPSession {

    /// Client for a saved connection. Nil `password` loads the secret from `store` (Keychain);
    /// an explicit value (including `""`) skips the lookup — used by the editor's "Test" button.
    public static func client(
        for connection: SFTPConnection,
        password: String? = nil,
        keyPassphrase: String? = nil,
        store: SFTPConnectionStore = .shared,
        hostKeys: HostKeyStore = .shared
    ) -> SFTPClient? {
        guard case .ready(let client) = resolve(for: connection, password: password,
                                                keyPassphrase: keyPassphrase,
                                                store: store, hostKeys: hostKeys) else {
            return nil
        }
        return client
    }

    /// Why a client could not be built, so a refused Keychain read is reported and retried rather than
    /// silently becoming a credential-less connection the server rejects, blaming the password.
    public enum Resolution: Sendable {
        case ready(SFTPClient)
        /// No host — nothing to connect to (see ``SFTPTarget/init(connection:password:keyPassphrase:)``).
        case incomplete
        /// A stored secret exists but could not be read.
        case credentialsUnavailable(CredentialLookup)
    }

    /// - Parameter credentialIdentity: whose secrets to read (default `connection`). Secrets are keyed by
    ///   `user@host:port`, so the editor passes the *saved* connection — "Test" finds an unretyped password.
    public static func resolve(
        for connection: SFTPConnection,
        password: String? = nil,
        keyPassphrase: String? = nil,
        credentialIdentity: SFTPConnection? = nil,
        store: SFTPConnectionStore = .shared,
        hostKeys: HostKeyStore = .shared
    ) -> Resolution {
        let secretsOwner = credentialIdentity ?? connection

        // An explicit value (including "") wins; nil falls back to the Keychain —
        // so editing the field is honoured by Test without having to save first.
        var resolvedPassword = password
        if resolvedPassword == nil {
            let lookup = store.passwordLookup(for: secretsOwner)
            switch lookup {
            case .found(_, let secret): resolvedPassword = secret
            case .notFound: break
            case .denied, .failed: return .credentialsUnavailable(lookup)
            }
        }

        var phrase = keyPassphrase
        // Keyed off the draft's key path but read from the saved identity: the `privateKeyPath`
        // guard stops a refusal on an unused passphrase entry blocking a password-only connection.
        if phrase == nil, connection.privateKeyPath != nil {
            let lookup = store.keyPassphraseLookup(for: secretsOwner)
            switch lookup {
            case .found(_, let secret): phrase = secret
            case .notFound: break
            case .denied, .failed: return .credentialsUnavailable(lookup)
            }
        }

        guard let target = SFTPTarget(connection: connection, password: resolvedPassword,
                                      keyPassphrase: phrase) else {
            return .incomplete
        }
        return .ready(SFTPClient(target: target, hostKeys: hostKeys))
    }

    /// Wrap an already-resolved target (engine URL path, tests).
    public static func client(
        for target: SFTPTarget,
        hostKeys: HostKeyStore = .shared
    ) -> SFTPClient {
        SFTPClient(target: target, hostKeys: hostKeys)
    }

    /// Client from an `sftp://` URL; password from inline userinfo or the connection store
    /// (see ``SFTPTarget/init(url:)``). Nil when the URL lacks a host/user.
    public static func client(
        for url: URL,
        hostKeys: HostKeyStore = .shared
    ) -> SFTPClient? {
        guard let target = SFTPTarget(url: url) else { return nil }
        return SFTPClient(target: target, hostKeys: hostKeys)
    }
}
