import Foundation

/// A saved SFTP server the user can browse and transfer files with. The
/// password is NOT stored here — it lives in the Keychain, keyed by the
/// connection's identity — so persisting the list is safe.
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

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22,
                username: String, initialPath: String = ".", useAgent: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.initialPath = initialPath
        self.useAgent = useAgent
    }

    /// The Keychain lookup key for this server's password. Scoped by
    /// user@host:port so two accounts on one host don't collide, and so an
    /// ad-hoc `sftp://user@host/path` download resolves the same secret.
    public var credentialKey: String { "\(username)@\(host):\(port)" }

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

    public init(name: String, isDirectory: Bool, size: Int64, modified: Date?, permissions: UInt32) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

/// Pure remote-path arithmetic for the SFTP browser. libssh2 resolves relative
/// paths against the login home, so "." is home; children are joined and
/// parents trimmed as plain POSIX strings.
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

    /// A name not present in `existing`, appending " (n)" before the extension on
    /// collision: "report.pdf" → "report (1).pdf", "archive.tar" → "archive (1).tar",
    /// "notes" → "notes (1)". Used to rename an upload rather than overwrite a
    /// same-named remote entry. `n` climbs until a free name is found.
    public static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }
}

/// A typed failure from an SFTP operation, carrying libssh2's detail message.
public struct SFTPError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case resolve, connect, handshake, hostKey, hostKeyMismatch
        case auth, sftp, open, io, aborted, mkdir, remove, stat, unknown
    }
    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}
