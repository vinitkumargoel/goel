import Foundation

public enum SFTPSession {

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

    /// A refused Keychain read must surface here, not degrade into a credential-less connect attempt.
    public enum Resolution: Sendable {
        case ready(SFTPClient)
        case incomplete
        case credentialsUnavailable(CredentialLookup)
    }

    public static func resolve(
        for connection: SFTPConnection,
        password: String? = nil,
        keyPassphrase: String? = nil,
        credentialIdentity: SFTPConnection? = nil,
        store: SFTPConnectionStore = .shared,
        hostKeys: HostKeyStore = .shared
    ) -> Resolution {
        let secretsOwner = credentialIdentity ?? connection

        // An explicit value wins, "" included; only nil may fall back to the Keychain.
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
        // The privateKeyPath guard stops a denied passphrase read from blocking a password-only connect.
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

    public static func client(
        for target: SFTPTarget,
        hostKeys: HostKeyStore = .shared
    ) -> SFTPClient {
        SFTPClient(target: target, hostKeys: hostKeys)
    }

    public static func client(
        for url: URL,
        hostKeys: HostKeyStore = .shared
    ) -> SFTPClient? {
        guard let target = SFTPTarget(url: url) else { return nil }
        return SFTPClient(target: target, hostKeys: hostKeys)
    }
}
