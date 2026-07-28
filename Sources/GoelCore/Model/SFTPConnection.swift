import Foundation

/// A saved SFTP server the user can browse and transfer files with. The password is NOT stored here —
/// it lives in the Keychain, keyed by the connection's identity — so persisting the list is safe.
public struct SFTPConnection: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    /// Directory the browser opens to (a server-absolute path, or "." for home).
    public var initialPath: String
    /// Try the running ssh-agent in addition to the stored password.
    public var useAgent: Bool
    /// Path to an SSH private key to authenticate with, or nil for password/agent auth only. Its
    /// passphrase (if any) lives in the Keychain under ``keyPassphraseKey``, never here.
    public var privateKeyPath: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22,
                username: String, initialPath: String = ".", useAgent: Bool = false,
                privateKeyPath: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.initialPath = initialPath
        self.useAgent = useAgent
        self.privateKeyPath = privateKeyPath
    }

    /// Keychain lookup key for this server's password, scoped by user@host:port so two accounts on one
    /// host don't collide and an ad-hoc `sftp://user@host/path` download resolves the same secret.
    public var credentialKey: String { "\(username)@\(host):\(port)" }

    /// Keychain key for the private key's passphrase. Suffixed so it can never
    /// collide with the password entry under ``credentialKey``.
    public var keyPassphraseKey: String { "\(credentialKey)#keyphrase" }

    /// A display label for the browser title bar.
    public var label: String { name.isEmpty ? "\(username)@\(host)" : name }
}

/// A single remote directory entry returned by a listing.
public struct SFTPEntry: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    public var permissions: UInt32
    /// Whether the entry ITSELF is a symlink; `isDirectory` still describes what it resolves to, so a
    /// link to a folder is both — the browser opens it like a folder yet still badges it as a link.
    public var isSymlink: Bool
    /// Where the link points, as the server reported it. Empty for non-links and
    /// for links whose target could not be read.
    public var linkTarget: String
    public var ownerID: UInt32
    public var groupID: UInt32

    public init(name: String, isDirectory: Bool, size: Int64, modified: Date?,
                permissions: UInt32, isSymlink: Bool = false, linkTarget: String = "",
                ownerID: UInt32 = 0, groupID: UInt32 = 0) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        self.ownerID = ownerID
        self.groupID = groupID
    }
}

/// Pure remote-path arithmetic for the SFTP browser. libssh2 resolves relative paths against the login
/// home, so "." is home; children are joined and parents trimmed as plain POSIX strings.
public enum SFTPBrowserPaths {
    /// Append a child name to a directory path.
    public static func join(_ base: String, _ child: String) -> String {
        if base == "." || base.isEmpty { return child }
        return base.hasSuffix("/") ? base + child : base + "/" + child
    }

    /// The parent directory of a path ("." = home, "/" = filesystem root).
    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }        // "/foo" -> "/"
        return String(path[path.startIndex..<slash])
    }

    /// Whether a server-supplied listing name is safe to join onto a remote path: no separators, no `..`,
    /// so a hostile entry can't steer an upload outside the browsed tree. Hidden ".config" names stay.
    public static func isSafeChildName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// A name not in `existing`, appending " (n)" before the extension, so an upload renames rather than
    /// overwrites. `n` is capped: `existing` is server-controlled; past the cap a random suffix is used.
    public static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        func candidate(_ suffix: String) -> String {
            ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
        }
        for n in 1...9_999 {
            let name = candidate(String(n))
            if !existing.contains(name) { return name }
        }
        while true {
            let name = candidate(UUID().uuidString.prefix(8).lowercased())
            if !existing.contains(name) { return name }
        }
    }
}

/// A typed failure from an SFTP operation, carrying libssh2's detail message.
public struct SFTPError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case resolve, connect, handshake, hostKey, hostKeyMismatch
        case auth, sftp, open, io, aborted, mkdir, remove, rename, stat, unknown
        /// Stored secret unreadable (prompt refused, keychain locked, file unreadable). Distinct from
        /// ``auth``: nothing reached the server, so retrying the read can fix it, re-typing cannot.
        case credentialsUnavailable
    }
    public var kind: Kind
    /// Plain-language text written for the person using the app.
    public var message: String
    /// Underlying libssh2/OS text, kept out of ``message`` so the UI shows it as secondary — libssh2 emits
    /// "Unable to exchange encryption keys" for most handshake faults regardless of the real cause.
    public var detail: String?

    public init(kind: Kind, message: String, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
    }

    /// Phrase a refused/failed secret read for the person using the app. Deliberately avoids "check your
    /// password": nothing was sent to the server, so the password is not what's wrong.
    public static func credentialsUnavailable(_ lookup: CredentialLookup,
                                              host: String) -> SFTPError {
        let message: String
        switch lookup {
        case .denied:
            message = "Goel wasn't allowed to read the saved secret for \(host) from your Keychain. Choose Allow when macOS asks, then try again."
        case .failed:
            message = "The saved secret for \(host) couldn't be read from your Keychain. Re-enter it and save."
        case .found, .notFound:
            message = "No saved secret for \(host)."
        }
        return SFTPError(kind: .credentialsUnavailable, message: message,
                         detail: lookup.statusDetail)
    }
}
