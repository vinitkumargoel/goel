import Foundation

/// How far an upload has got. Persisted, so a crash between "bytes landed" and "app recorded it" is recoverable rather than silent.
public enum RemoteUploadState: String, Codable, Sendable, Hashable {
    /// Waiting for the download to finish, or queued behind the concurrency cap.
    case pending
    /// Bytes are moving; written to disk *before* the first byte leaves.
    case uploading
    /// Landed and verified under its final name.
    case uploaded
    /// Attempted and refused; `failureMessage` says why and the local copy is intact.
    case failed
    /// Feature switched off, or the target server no longer exists — intent preserved, not erased.
    case held

    public var isFinished: Bool { self == .uploaded }
    public var isInFlight: Bool { self == .uploading }
}

/// A saved SFTP server chosen as a download's destination, plus the state of the transfer to it.
///
/// An optional field on ``DownloadTask`` rather than an enum over `saveDirectory`: the local path is read in dozens of places that all stay correct as-is, and an old persisted task decodes untouched.
public struct RemoteDestination: Codable, Sendable, Hashable {

    public var connectionID: UUID

    /// Snapshot of the server's name, so a task whose server was deleted can still say which one it meant.
    public var serverLabel: String

    /// Validated remote directory — always `"."` or server-absolute. See ``RemotePathSafety/validateDirectory(_:)``.
    public var directory: String

    /// Delete the local copy once the upload verifies. Off by default: sending is a copy, and destructive-by-default is wrong for an unproven pipeline.
    public var removeLocalAfterUpload: Bool

    public var state: RemoteUploadState

    /// Full remote path once the rename lands — what "Open on server" and the history entry point at.
    public var remotePath: String?

    /// Bytes sent in the current attempt; persisted only so a relaunch shows a sensible resting position.
    public var bytesTransferred: Int64

    /// Why the last attempt failed, in the words the UI shows.
    public var failureMessage: String?

    /// Attempts in the current failure streak, driving backoff. Reset on success and on a manual retry.
    public var attempt: Int

    /// Fixed at creation so a retry cleans up the *same* temporary, while two tasks writing one name still get distinct ones.
    public var token: String

    public init(connectionID: UUID,
                serverLabel: String,
                directory: String,
                removeLocalAfterUpload: Bool = false,
                state: RemoteUploadState = .pending,
                remotePath: String? = nil,
                bytesTransferred: Int64 = 0,
                failureMessage: String? = nil,
                attempt: Int = 0,
                token: String = RemoteDestination.newToken()) {
        self.connectionID = connectionID
        self.serverLabel = serverLabel
        self.directory = directory
        self.removeLocalAfterUpload = removeLocalAfterUpload
        self.state = state
        self.remotePath = remotePath
        self.bytesTransferred = bytesTransferred
        self.failureMessage = failureMessage
        self.attempt = attempt
        self.token = token
    }

    /// Eight hex chars — enough to separate concurrent uploads without making an orphan unrecognisable in a listing.
    public static func newToken() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    /// The one state where a missing local file is expected — consulted by the reconcile sweep, which would otherwise drop the row five seconds after the upload succeeded.
    public var localCopyIntentionallyRemoved: Bool {
        state == .uploaded && removeLocalAfterUpload
    }

    /// A short label for the task row, e.g. `"media-box:/srv/media"`.
    public var displayLocation: String {
        directory == "." ? serverLabel : "\(serverLabel):\(directory)"
    }

    private enum CodingKeys: String, CodingKey {
        case connectionID, serverLabel, directory, removeLocalAfterUpload
        case state, remotePath, bytesTransferred, failureMessage, attempt, token
    }

    /// Every field falls back, matching the rest of the persisted model, so a blob from an earlier build of this feature still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectionID = try c.decode(UUID.self, forKey: .connectionID)
        serverLabel = try c.decodeIfPresent(String.self, forKey: .serverLabel) ?? "Server"
        directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? "."
        removeLocalAfterUpload = try c.decodeIfPresent(Bool.self, forKey: .removeLocalAfterUpload) ?? false
        state = try c.decodeIfPresent(RemoteUploadState.self, forKey: .state) ?? .pending
        remotePath = try c.decodeIfPresent(String.self, forKey: .remotePath)
        bytesTransferred = try c.decodeIfPresent(Int64.self, forKey: .bytesTransferred) ?? 0
        failureMessage = try c.decodeIfPresent(String.self, forKey: .failureMessage)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? RemoteDestination.newToken()
    }
}
