import Foundation
import SSHBridge

/// The connection + auth details for one SFTP target. Passwords are resolved by
/// the caller (Keychain / inline userinfo) and never persisted here.
public struct SFTPTarget: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var useAgent: Bool
    /// Path to an SSH private key, or nil to skip key auth.
    public var privateKeyPath: String?
    /// Passphrase for `privateKeyPath`, or nil when the key is unencrypted.
    public var keyPassphrase: String?

    public init(host: String, port: Int = 22, username: String,
                password: String?, useAgent: Bool = false,
                privateKeyPath: String? = nil, keyPassphrase: String? = nil) {
        self.host = host
        // Clamp to a valid TCP port so the C marshaling (`Int32(port)` in
        // `withAuth`) can never trap on out-of-range input from the editor's
        // free-text port field.
        self.port = (1...65535).contains(port) ? port : 22
        self.username = username
        self.password = password
        self.useAgent = useAgent
        self.privateKeyPath = privateKeyPath
        self.keyPassphrase = keyPassphrase
    }

    public init?(connection: SFTPConnection, password: String?,
                 keyPassphrase: String? = nil) {
        guard !connection.host.isEmpty else { return nil }
        self.init(host: connection.host, port: connection.port,
                  username: connection.username, password: password,
                  useAgent: connection.useAgent,
                  privateKeyPath: connection.privateKeyPath,
                  keyPassphrase: keyPassphrase)
    }

    /// Build a target from an `sftp://[user[:pass]@]host[:port]/…` URL, filling a
    /// missing password from the store. Returns nil if there's no host/user.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "sftp", let host = url.host, !host.isEmpty,
              let user = url.user, !user.isEmpty else { return nil }
        let port = url.port ?? 22
        let inline = url.password
        let stored = inline == nil
            ? SFTPConnectionStore.shared.password(user: user, host: host, port: port)
            : nil
        self.init(host: host, port: port, username: user,
                  password: inline ?? stored, useAgent: true)
    }
}

/// Interactive + streaming SFTP over the ``SSHBridge`` C shim (libssh2).
///
/// A client is a cheap value that names a server and a *role*; the connection
/// itself lives in ``SFTPSessionPool``, keyed by both. Operations are posted to
/// that connection's owning thread, which is what keeps a libssh2 session — not
/// thread-safe — from ever crossing threads while still letting the handshake be
/// paid once instead of once per operation. Host keys are pinned
/// trust-on-first-use through ``HostKeyStore``.
public struct SFTPClient: Sendable {

    public let target: SFTPTarget
    private let hostKeys: HostKeyStore
    /// Which pooled connection this client's operations ride on. A client is
    /// cheap and value-typed, so a caller takes a differently-roled copy rather
    /// than re-resolving credentials — see ``onBackground()`` / ``forTransfer(_:)``.
    public let role: SFTPSessionRole

    public init(target: SFTPTarget, hostKeys: HostKeyStore = .shared,
                role: SFTPSessionRole = .interactive) {
        self.target = target
        self.hostKeys = hostKeys
        self.role = role
    }

    /// The same server, on the connection reserved for recursive walks, sizing,
    /// thumbnails and search — so a long scan never delays a folder click.
    public func onBackground() -> SFTPClient {
        SFTPClient(target: target, hostKeys: hostKeys, role: .background)
    }

    /// The same server, on a connection dedicated to one transfer job. Every file
    /// in a folder transfer must share this client so the job pays a single
    /// handshake rather than one per file. Release it with
    /// ``finishTransfer(_:)`` when the job ends.
    public func forTransfer(_ id: UUID) -> SFTPClient {
        SFTPClient(target: target, hostKeys: hostKeys, role: .transfer(id))
    }

    /// Give back the connection a transfer job was holding.
    public func finishTransfer(_ id: UUID) async {
        await SFTPSessionPool.shared.releaseTransfer(id, target: target)
    }

    /// Claim `count` connection slots on this server together, waiting until
    /// that many are free.
    ///
    /// A relay copy needs two connections on the same server at once — one
    /// reading, one writing — and the reader blocks the writer. Taking them one
    /// at a time lets two concurrent relays each hold one and wait forever for
    /// the other's, so they are claimed as a pair. Balance with
    /// ``releaseSlots(_:)``.
    public func reserveSlots(_ count: Int) async {
        await SFTPSessionPool.shared.reserve(target, count: count)
    }

    public func releaseSlots(_ count: Int) async {
        await SFTPSessionPool.shared.release(target, count: count)
    }

    /// Drop every pooled connection to this server. Call after editing its
    /// credentials or resetting its pinned host key.
    public func disconnect() async {
        await SFTPSessionPool.shared.disconnectAll(matching: target)
    }

    // MARK: Interactive operations

    /// Connect + authenticate only. Returns the server's fingerprint.
    public func probe() async throws -> String {
        SFTPResult(await runOnThread(expected: try await pinnedFingerprint(),
                                     name: "goel.sftp-probe") { auth in gsb_probe(auth) }).fingerprint
    }

    /// Connect far enough to read the server's host key, then hang up — no
    /// credential is offered. This is what makes first-contact approval worth
    /// anything: the fingerprint can be shown, and refused, before the password
    /// has ever been on the wire.
    public func hostKeyFingerprint() async throws -> String {
        let result = await runOnThread(expected: nil, name: "goel.sftp-hostkey") { auth in
            gsb_hostkey(auth)
        }
        guard result.code == GSB_OK else {
            throw SFTPResult(result).asError(host: target.host, port: target.port,
                                             username: target.username)
        }
        return SFTPResult(result).fingerprint
    }

    public func list(_ path: String) async throws -> [SFTPEntry] {
        let collector = ListCollector()
        _ = try await run { session in
            let box = Unmanaged.passRetained(collector)
            defer { box.release() }
            return gsb_list(session, path, sftpEntryThunk, box.toOpaque())
        }
        return collector.entries
    }

    public func size(_ remote: String) async throws -> Int64 {
        try await run { session in gsb_size(session, remote) }.value
    }

    public func mkdir(_ path: String) async throws {
        _ = try await run { session in gsb_mkdir(session, path) }
    }

    public func remove(_ path: String, isDirectory: Bool) async throws {
        _ = try await run { session in gsb_remove(session, path, isDirectory ? 1 : 0) }
    }

    /// Rename or move `from` to `to` on the server (works across directories).
    public func rename(_ from: String, to: String) async throws {
        _ = try await run { session in gsb_rename(session, from, to) }
    }

    // MARK: Metadata

    /// Full attributes of one remote item.
    ///
    /// `followSymlink: false` (the default) describes the *link*, not what it
    /// points at — which is what an info panel must show, since a link's own size
    /// and permissions are not its target's.
    public func attributes(_ path: String, followSymlink: Bool = false) async throws -> SFTPAttributes {
        let box = StatBox()
        _ = try await run { session in
            box.withPointer { out in
                followSymlink ? gsb_stat(session, path, out) : gsb_lstat(session, path, out)
            }
        }
        return box.attributes
    }

    /// Where a symbolic link points, as the server records it — which may be a
    /// relative path, and may not exist.
    public func linkTarget(_ path: String) async throws -> String {
        let box = PathBox()
        _ = try await run { session in
            box.withBuffer { buf, cap in gsb_readlink(session, path, buf, cap) }
        }
        return box.value
    }

    /// Canonicalise a path server-side, resolving `..`, `.` and symlinks.
    public func canonicalPath(_ path: String) async throws -> String {
        let box = PathBox()
        _ = try await run { session in
            box.withBuffer { buf, cap in gsb_realpath(session, path, buf, cap) }
        }
        return box.value
    }

    /// Change an existing item's permission bits. The file-type bits are
    /// preserved server-side, so this cannot turn a directory into a file.
    public func setPermissions(_ path: String, _ permissions: UInt32) async throws {
        _ = try await run { session in gsb_setstat(session, path, UInt(permissions)) }
    }

    /// Free and total bytes on the volume holding `path`.
    ///
    /// Returns nil rather than throwing when the server lacks the
    /// `statvfs@openssh.com` extension: free space is a nicety, and a server
    /// without it should simply show nothing instead of raising an error the user
    /// can do nothing about.
    public func freeSpace(_ path: String) async throws -> SFTPVolumeSpace? {
        let box = SpaceBox()
        let channel = try await channel()
        let result = await channel.perform { session in
            box.withPointer { out in gsb_statvfs(session, path, out) }
        }
        learnIfNeeded(channel: channel)
        guard result.code == GSB_OK else { return nil }
        return box.space
    }

    /// Download a remote file to a local URL, reporting (bytesSoFar, total).
    /// `shouldContinue`, when supplied, is polled on every progress tick; return
    /// false to abort the transfer (used to make an interactive drag-out
    /// cancellable so a cancelled drag doesn't download the whole file).
    public func downloadToFile(remote: String, localURL: URL,
                               maxBytesPerSecond: Int64 = 0,
                               shouldContinue: (@Sendable () -> Bool)? = nil,
                               progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw SFTPError(kind: .io, message: "Could not open the local file for writing")
        }
        let ctx = TransferContext(
            onWrite: { buf in (try? handle.write(contentsOf: buf)) != nil },
            onProgress: { total, sofar in progress(sofar, total); return shouldContinue?() ?? true },
            onRead: nil)
        defer { try? handle.close() }
        let result = try await runTransfer(ctx) { session, box in
            gsb_download(session, remote, 0, maxBytesPerSecond, sftpWriteThunk, sftpProgressThunk, box)
        }
        // The shim counts bytes handed to the write callback, not bytes that
        // reached the disk; `result.value` carries the size the server reported.
        // Assert the file actually holds them, so a short write can never settle
        // as a finished transfer with a truncated file on disk.
        let written = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        if let short = TransferCompletion.shortfall(expected: result.value, written: written) {
            throw SFTPError(kind: .io,
                            message: "The download of “\(localURL.lastPathComponent)” ended early — \(short) byte\(short == 1 ? "" : "s") never arrived.")
        }
    }

    /// Upload a local file to a remote path, reporting (bytesSoFar, total).
    /// `maxBytesPerSecond` throttles the send rate (0 = unlimited).
    /// `shouldContinue`, when supplied, is polled on every progress tick; return
    /// false to abort the upload (drives interactive/background cancellation).
    public func upload(localURL: URL, remote: String,
                       maxBytesPerSecond: Int64 = 0,
                       shouldContinue: (@Sendable () -> Bool)? = nil,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SFTPError(kind: .io, message: "Could not open the local file for reading")
        }
        // A size we can't read would silently disable the shim's "was the whole
        // file sent?" assertion (`total == 0` means "size unknown" there), so a
        // truncated upload would report success. Refuse rather than guess.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
              let total = attributes[.size] as? Int64 else {
            throw SFTPError(kind: .io,
                            message: "Could not read the size of “\(localURL.lastPathComponent)”, so Goel can’t tell whether the whole file was sent.")
        }
        // A local read that *throws* must not be folded into the `return 0` that
        // signals a clean EOF — the C upload loop would treat it as end-of-file,
        // truncate-write only the bytes sent so far, and report success. Capture
        // the error and return -1 so the transfer aborts and surfaces it.
        let readError = ReadErrorBox()
        let ctx = TransferContext(
            onWrite: { _ in true },
            onProgress: { total, sofar in progress(sofar, total); return shouldContinue?() ?? true },
            onRead: { buf in
                do {
                    guard let chunk = try handle.read(upToCount: buf.count), !chunk.isEmpty else { return 0 }
                    _ = chunk.copyBytes(to: buf.bindMemory(to: UInt8.self))
                    return chunk.count
                } catch {
                    readError.set(error)
                    return -1
                }
            })
        defer { try? handle.close() }
        do {
            _ = try await runTransfer(ctx) { session, box in
                gsb_upload(session, remote, total, maxBytesPerSecond, sftpReadThunk, sftpProgressThunk, box)
            }
        } catch let e as SFTPError where e.kind == .aborted {
            // Distinguish "the local file couldn't be read" from a user cancel,
            // both of which reach the C shim as an abort.
            if let underlying = readError.value {
                throw SFTPError(kind: .io,
                                message: "Could not read the local file: \(underlying.localizedDescription)")
            }
            throw e
        }
    }

    /// Upload from a caller-supplied byte source rather than a local file.
    ///
    /// `read` fills the buffer and returns the count, 0 at end-of-stream, or a
    /// negative number to abort — the same contract as the C shim's read
    /// callback. `total` must be the exact number of bytes `read` will produce:
    /// the shim uses it to assert the whole file arrived, and a wrong value would
    /// let a truncated upload report success.
    ///
    /// This is what makes a remote→remote copy possible without spooling to disk
    /// (see ``SFTPRelay``).
    public func uploadStream(remote: String, total: Int64,
                             maxBytesPerSecond: Int64 = 0,
                             shouldContinue: (@Sendable () -> Bool)? = nil,
                             read: @escaping @Sendable (UnsafeMutableRawBufferPointer) -> Int,
                             progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let ctx = TransferContext(
            onWrite: { _ in true },
            onProgress: { total, sofar in progress(sofar, total); return shouldContinue?() ?? true },
            onRead: read)
        _ = try await runTransfer(ctx) { session, box in
            gsb_upload(session, remote, total, maxBytesPerSecond, sftpReadThunk, sftpProgressThunk, box)
        }
    }

    // MARK: Streaming download (for the queued-download engine)

    /// Low-level resumable download. The caller's `write` returns false to fail,
    /// `progress` returns false to abort (pause/cancel). Never throws — inspect
    /// the returned result. Learns the host key on first connect.
    public func streamingDownload(remote: String, resumeFrom: Int64, maxBytesPerSecond: Int64,
                                  write: @escaping @Sendable (UnsafeRawBufferPointer) -> Bool,
                                  progress: @escaping @Sendable (Int64, Int64) -> Bool) async -> SFTPResult {
        let ctx = TransferContext(onWrite: write, onProgress: progress, onRead: nil)
        let channel: SFTPSessionChannel
        do {
            channel = try await self.channel()
        } catch let e as SFTPError {
            // This entry point reports through its result rather than throwing, so
            // a refusal has to be phrased as one.
            return SFTPResult(code: Int32(GSB_ERR_HOSTKEY), message: e.message)
        } catch {
            return SFTPResult(code: Int32(GSB_ERR_HOSTKEY), message: error.localizedDescription)
        }
        let box = Unmanaged.passRetained(ctx)
        let result = await channel.perform { session in
            gsb_download(session, remote, resumeFrom, maxBytesPerSecond,
                         sftpWriteThunk, sftpProgressThunk, box.toOpaque())
        }
        box.release()
        learnIfNeeded(channel: channel)
        return SFTPResult(result)
    }

    // MARK: Plumbing

    /// Run one blocking C call on its own thread. No trust policy of its own —
    /// the caller decides what `expected` should be (see ``pinnedFingerprint()``).
    private func runOnThread(expected: String?, name: String,
                             _ body: @escaping @Sendable (UnsafePointer<GSBAuth>) -> GSBResult) async -> GSBResult {
        await withCheckedContinuation { (cont: CheckedContinuation<GSBResult, Never>) in
            let thread = Thread {
                let r = SFTPSessionChannel.withAuth(self.target, expected: expected, body)
                cont.resume(returning: r)
            }
            thread.name = name
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// The pooled connection this client's role maps to.
    private func channel() async throws -> SFTPSessionChannel {
        let expected = try await pinnedFingerprint()
        return await SFTPSessionPool.shared.channel(for: target, role: role, expected: expected)
    }

    /// Run a session-scoped op on the pooled connection; throw on failure and pin
    /// the host key on first successful connect.
    @discardableResult
    private func run(_ body: @escaping @Sendable (OpaquePointer) -> GSBResult) async throws -> GSBResult {
        let channel = try await channel()
        let result = await channel.perform(body)
        learnIfNeeded(channel: channel)
        guard result.code == GSB_OK else {
            throw SFTPResult(result).asError(host: target.host, port: target.port,
                                             username: target.username)
        }
        return result
    }

    /// As ``run(_:)``, but hands the C call a retained context box carrying its
    /// read/write/progress callbacks. The box outlives the call and is released
    /// only after the session thread has finished with it.
    private func runTransfer(_ ctx: TransferContext,
                             _ body: @escaping @Sendable (OpaquePointer, UnsafeMutableRawPointer) -> GSBResult) async throws -> GSBResult {
        let channel = try await channel()
        let box = Unmanaged.passRetained(ctx)
        let result = await channel.perform { session in body(session, box.toOpaque()) }
        box.release()
        learnIfNeeded(channel: channel)
        guard result.code == GSB_OK else {
            throw SFTPResult(result).asError(host: target.host, port: target.port,
                                             username: target.username)
        }
        return result
    }

    /// The endpoint as the user wrote it, for messages.
    private var endpoint: String {
        target.port == 22 ? target.host : "\(target.host):\(target.port)"
    }

    /// The fingerprint this connection must match, resolving first contact.
    ///
    /// Three outcomes for a host with no pin. With an approver installed the key
    /// is read in a credential-free pre-flight and pinned only if the user
    /// accepts it, so the password is never offered to a host whose identity the
    /// user hasn't seen. Without one — the daemon, the CLI paths, tests — the
    /// classic trust-on-first-use applies and ``learnIfNeeded(channel:)``
    /// pins after the fact, because there is nobody to ask. A pin record we can't
    /// read refuses outright: silently re-learning would downgrade an already
    /// verified server back to first contact.
    private func pinnedFingerprint() async throws -> String? {
        switch hostKeys.lookup(host: target.host, port: target.port) {
        case .pinned(let fingerprint):
            return fingerprint
        case .unavailable:
            throw SFTPError(kind: .hostKey,
                            message: "Goel can’t read its record of this server’s identity, so it won’t connect. Reset the pinned host key for \(endpoint) and re-verify.")
        case .none:
            guard let approver = HostKeyTrust.shared.approver else { return nil }
            let fingerprint = try await hostKeyFingerprint()
            guard await approver.approveFirstContact(host: target.host, port: target.port,
                                                     fingerprint: fingerprint) else {
                throw SFTPError(kind: .hostKey,
                                message: "You didn’t confirm the identity of \(endpoint), so Goel didn’t connect.")
            }
            hostKeys.setFingerprint(fingerprint, host: target.host, port: target.port)
            return fingerprint
        }
    }

    /// On a first, un-pinned connect that got far enough to read the host key,
    /// remember it so later connects are pinned. Only reachable when no approver
    /// is installed — with one, ``pinnedFingerprint()`` has already pinned or
    /// refused before any credential went on the wire.
    ///
    /// Reads the fingerprint off the live channel rather than off a result: with
    /// pooled connections the handshake happens once, so only the operation that
    /// happened to open the connection would carry it.
    private func learnIfNeeded(channel: SFTPSessionChannel) {
        guard case .none = hostKeys.lookup(host: target.host, port: target.port),
              let fp = channel.fingerprint, !fp.isEmpty else { return }
        hostKeys.setFingerprint(fp, host: target.host, port: target.port)
    }

}

/// A Swift view of a `GSBResult`.
public struct SFTPResult: Sendable {
    public let code: Int32
    public let value: Int64
    public let fingerprint: String
    public let message: String

    /// A refusal decided in Swift before any C call was made — an unreadable pin
    /// record, or a declined first-contact approval — for the entry points that
    /// report through a result instead of throwing.
    init(code: Int32, message: String) {
        self.code = code
        self.value = 0
        self.fingerprint = ""
        self.message = message
    }

    init(_ r: GSBResult) {
        code = Int32(r.code)
        value = r.value
        fingerprint = withUnsafeBytes(of: r.fingerprint) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        message = withUnsafeBytes(of: r.message) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    public var isAborted: Bool { code == GSB_ERR_ABORTED }
    public var isSuccess: Bool { code == GSB_OK }

    public var asError: SFTPError {
        let kind: SFTPError.Kind
        switch Int(code) {
        case Int(GSB_ERR_RESOLVE): kind = .resolve
        case Int(GSB_ERR_CONNECT): kind = .connect
        case Int(GSB_ERR_HANDSHAKE): kind = .handshake
        case Int(GSB_ERR_HOSTKEY): kind = .hostKey
        case Int(GSB_ERR_HOSTKEY_MISMATCH): kind = .hostKeyMismatch
        case Int(GSB_ERR_AUTH): kind = .auth
        case Int(GSB_ERR_SFTP): kind = .sftp
        case Int(GSB_ERR_OPEN): kind = .open
        case Int(GSB_ERR_IO): kind = .io
        case Int(GSB_ERR_ABORTED): kind = .aborted
        case Int(GSB_ERR_MKDIR): kind = .mkdir
        case Int(GSB_ERR_REMOVE): kind = .remove
        case Int(GSB_ERR_RENAME): kind = .rename
        case Int(GSB_ERR_STAT): kind = .stat
        default: kind = .unknown
        }
        return SFTPError(kind: kind, message: message.isEmpty ? "SFTP error \(code)" : message)
    }

    /// The failure phrased for the person using the app, with the raw libssh2 /
    /// OS text demoted to ``SFTPError/detail``.
    ///
    /// This exists because libssh2's own strings mislead: it reports nearly every
    /// handshake fault as "Unable to exchange encryption keys", which reads as a
    /// crypto-incompatibility even when the real cause is the connection being
    /// blocked or dropped. Surfacing that verbatim sends people to change server
    /// ciphers when nothing is wrong with the server.
    public func asError(host: String, port: Int, username: String) -> SFTPError {
        let raw = asError
        let endpoint = port == 22 ? host : "\(host):\(port)"
        let friendly: String
        switch raw.kind {
        case .resolve:
            friendly = "Can't find “\(host)”. Check the address, and that you're on the right network or VPN."
        case .connect:
            friendly = "Can't reach \(endpoint). Check the server is switched on and reachable — and if it's on your local network, that Goel is allowed to use it under System Settings ▸ Privacy & Security ▸ Local Network."
        case .handshake:
            friendly = "\(endpoint) accepted the connection but the secure handshake didn't finish. Check that it's an SSH/SFTP server on that port and that nothing is dropping the connection."
        case .hostKey:
            friendly = "\(endpoint) didn't present a host key, so its identity can't be verified."
        case .hostKeyMismatch:
            friendly = "The identity of \(endpoint) has changed since you last connected. If the server was genuinely rebuilt or rekeyed, use “Reset pinned host key” and reconnect — otherwise stop and check why."
        case .auth:
            friendly = "\(endpoint) refused the sign-in for “\(username)”. Check the password, or the private key and its passphrase."
        default:
            return raw
        }
        return SFTPError(kind: raw.kind, message: friendly,
                         detail: raw.message.isEmpty ? nil : raw.message)
    }
}

// MARK: - Callback contexts + C thunks

/// Holds the Swift closures the C callbacks reach through an opaque pointer.
/// Used single-threaded within one blocking C call, so no locking is needed.
final class TransferContext: @unchecked Sendable {
    let onWrite: @Sendable (UnsafeRawBufferPointer) -> Bool
    let onProgress: @Sendable (Int64, Int64) -> Bool
    let onRead: (@Sendable (UnsafeMutableRawBufferPointer) -> Int)?

    init(onWrite: @escaping @Sendable (UnsafeRawBufferPointer) -> Bool,
         onProgress: @escaping @Sendable (Int64, Int64) -> Bool,
         onRead: (@Sendable (UnsafeMutableRawBufferPointer) -> Int)?) {
        self.onWrite = onWrite
        self.onProgress = onProgress
        self.onRead = onRead
    }
}

final class ListCollector: @unchecked Sendable {
    var entries: [SFTPEntry] = []
}

/// Carries a `GSBStat` out of a C call. The C shim fills it on the session
/// thread; the awaiting task reads it only after that call has returned, so the
/// hand-off needs no lock — the same discipline ``ListCollector`` relies on.
final class StatBox: @unchecked Sendable {
    private var raw = GSBStat()

    func withPointer(_ body: (UnsafeMutablePointer<GSBStat>) -> GSBResult) -> GSBResult {
        withUnsafeMutablePointer(to: &raw) { body($0) }
    }

    var attributes: SFTPAttributes {
        SFTPAttributes(exists: raw.exists != 0,
                       isDirectory: raw.is_dir != 0,
                       isSymlink: raw.is_link != 0,
                       size: raw.size,
                       modified: raw.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(raw.mtime)) : nil,
                       permissions: UInt32(truncatingIfNeeded: raw.perms),
                       ownerID: UInt32(truncatingIfNeeded: raw.uid),
                       groupID: UInt32(truncatingIfNeeded: raw.gid))
    }
}

/// Carries a NUL-terminated path out of a C call. Sized to the shim's own path
/// ceiling so a long `realpath` result is never silently cut short by *this*
/// buffer.
final class PathBox: @unchecked Sendable {
    private var buffer = [CChar](repeating: 0, count: 4096)

    func withBuffer(_ body: (UnsafeMutablePointer<CChar>, Int) -> GSBResult) -> GSBResult {
        buffer.withUnsafeMutableBufferPointer { raw in body(raw.baseAddress!, raw.count) }
    }

    var value: String { String(cString: buffer) }
}

/// Carries a `GSBSpace` out of a C call. See ``StatBox`` for the hand-off rule.
final class SpaceBox: @unchecked Sendable {
    private var raw = GSBSpace()

    func withPointer(_ body: (UnsafeMutablePointer<GSBSpace>) -> GSBResult) -> GSBResult {
        withUnsafeMutablePointer(to: &raw) { body($0) }
    }

    var space: SFTPVolumeSpace {
        SFTPVolumeSpace(totalBytes: raw.total_bytes, freeBytes: raw.free_bytes)
    }
}

/// Captures the first local-read failure during an upload so the caller can
/// report it, instead of the C loop mistaking the abort for a clean EOF. The
/// read callback (C thread) writes it; the awaiting task reads it after the
/// transfer thread has joined, so the `NSLock` guards that hand-off.
final class ReadErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    func set(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = error }
    }
    var value: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private func sftpWriteThunk(buf: UnsafePointer<CChar>?, len: Int,
                            ud: UnsafeMutableRawPointer?) -> Int {
    guard let buf, let ud, len > 0 else { return 0 }
    let ctx = Unmanaged<TransferContext>.fromOpaque(ud).takeUnretainedValue()
    let raw = UnsafeRawBufferPointer(start: buf, count: len)
    return ctx.onWrite(raw) ? len : 0
}

private func sftpReadThunk(buf: UnsafeMutablePointer<CChar>?, cap: Int,
                           ud: UnsafeMutableRawPointer?) -> Int {
    guard let buf, let ud, cap > 0 else { return -1 }
    let ctx = Unmanaged<TransferContext>.fromOpaque(ud).takeUnretainedValue()
    guard let onRead = ctx.onRead else { return 0 }
    let raw = UnsafeMutableRawBufferPointer(start: buf, count: cap)
    return onRead(raw)
}

private func sftpProgressThunk(ud: UnsafeMutableRawPointer?,
                               total: Int64, sofar: Int64) -> Int32 {
    guard let ud else { return 1 }
    let ctx = Unmanaged<TransferContext>.fromOpaque(ud).takeUnretainedValue()
    return ctx.onProgress(total, sofar) ? 0 : 1
}

private func sftpEntryThunk(ud: UnsafeMutableRawPointer?, name: UnsafePointer<CChar>?,
                            isDir: Int32, size: Int64, mtime: Int64, perms: UInt,
                            isLink: Int32, linkTarget: UnsafePointer<CChar>?,
                            uid: UInt, gid: UInt) {
    guard let ud, let name else { return }
    let collector = Unmanaged<ListCollector>.fromOpaque(ud).takeUnretainedValue()
    let entry = SFTPEntry(name: String(cString: name),
                          isDirectory: isDir != 0,
                          size: size,
                          modified: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil,
                          permissions: UInt32(truncatingIfNeeded: perms),
                          isSymlink: isLink != 0,
                          linkTarget: linkTarget.map { String(cString: $0) } ?? "",
                          ownerID: UInt32(truncatingIfNeeded: uid),
                          groupID: UInt32(truncatingIfNeeded: gid))
    collector.entries.append(entry)
}
