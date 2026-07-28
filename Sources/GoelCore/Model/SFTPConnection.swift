import Foundation

/// The password is never stored here — it lives in the Keychain, so persisting this list is safe.
public struct SFTPConnection: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var initialPath: String
    public var useAgent: Bool
    /// The key's passphrase lives in the Keychain under ``keyPassphraseKey``, never here.
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

    /// Scoped by user@host:port so two accounts on one host never resolve each other's secret.
    public var credentialKey: String { "\(username)@\(host):\(port)" }

    /// Suffixed so it can never collide with the password entry under ``credentialKey``.
    public var keyPassphraseKey: String { "\(credentialKey)#keyphrase" }

    public var label: String { name.isEmpty ? "\(username)@\(host)" : name }
}

public struct SFTPEntry: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    public var permissions: UInt32
    /// The entry ITSELF is a symlink; `isDirectory` still describes what it resolves to.
    public var isSymlink: Bool
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

public enum SFTPBrowserPaths {
    public static func join(_ base: String, _ child: String) -> String {
        if base == "." || base.isEmpty { return child }
        return base.hasSuffix("/") ? base + child : base + "/" + child
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[path.startIndex..<slash])
    }

    /// Server-supplied names: no separators and no `..`, or a hostile entry steers uploads out of the tree.
    public static func isSafeChildName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// `n` is capped because `existing` is server-controlled; past the cap a random suffix is used.
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

public struct SFTPError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case resolve, connect, handshake, hostKey, hostKeyMismatch
        case auth, sftp, open, io, aborted, mkdir, remove, rename, stat, unknown
        case credentialsUnavailable
    }
    public var kind: Kind
    public var message: String
    public var detail: String?

    public init(kind: Kind, message: String, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
    }

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
