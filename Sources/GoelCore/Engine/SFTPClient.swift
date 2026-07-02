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

    public init(host: String, port: Int = 22, username: String,
                password: String?, useAgent: Bool = false) {
        self.host = host
        // Clamp to a valid TCP port so the C marshaling (`Int32(port)` in
        // `withAuth`) can never trap on out-of-range input from the editor's
        // free-text port field.
        self.port = (1...65535).contains(port) ? port : 22
        self.username = username
        self.password = password
        self.useAgent = useAgent
    }

    public init?(connection: SFTPConnection, password: String?) {
        guard !connection.host.isEmpty else { return nil }
        self.init(host: connection.host, port: connection.port,
                  username: connection.username, password: password,
                  useAgent: connection.useAgent)
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

/// Interactive + streaming SFTP over the ``SSHBridge`` C shim (libssh2). Every
/// operation opens its own session on a dedicated thread and tears it down
/// before returning, so a libssh2 session never crosses threads. Host keys are
/// pinned trust-on-first-use through ``HostKeyStore``.
public struct SFTPClient: Sendable {

    public let target: SFTPTarget
    private let hostKeys: HostKeyStore

    public init(target: SFTPTarget, hostKeys: HostKeyStore = .shared) {
        self.target = target
        self.hostKeys = hostKeys
    }

    // MARK: Interactive operations

    /// Connect + authenticate only. Returns the server's fingerprint.
    public func probe() async throws -> String {
        SFTPResult(try await run { auth in gsb_probe(auth) }).fingerprint
    }

    public func list(_ path: String) async throws -> [SFTPEntry] {
        let collector = ListCollector()
        _ = try await run { auth in
            let box = Unmanaged.passRetained(collector)
            defer { box.release() }
            return gsb_list(auth, path, sftpEntryThunk, box.toOpaque())
        }
        return collector.entries
    }

    public func size(_ remote: String) async throws -> Int64 {
        try await run { auth in gsb_size(auth, remote) }.value
    }

    public func mkdir(_ path: String) async throws {
        _ = try await run { auth in gsb_mkdir(auth, path) }
    }

    public func remove(_ path: String, isDirectory: Bool) async throws {
        _ = try await run { auth in gsb_remove(auth, path, isDirectory ? 1 : 0) }
    }

    /// Download a remote file to a local URL, reporting (bytesSoFar, total).
    /// `shouldContinue`, when supplied, is polled on every progress tick; return
    /// false to abort the transfer (used to make an interactive drag-out
    /// cancellable so a cancelled drag doesn't download the whole file).
    public func downloadToFile(remote: String, localURL: URL,
                               shouldContinue: (@Sendable () -> Bool)? = nil,
                               progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw SFTPError(kind: .io, message: "Could not open the local file for writing")
        }
        let ctx = TransferContext(
            onWrite: { buf in (try? handle.write(contentsOf: Data(buffer: buf.bindMemory(to: UInt8.self)))) != nil },
            onProgress: { total, sofar in progress(sofar, total); return shouldContinue?() ?? true },
            onRead: nil)
        defer { try? handle.close() }
        _ = try await runTransfer(ctx) { auth, box in
            gsb_download(auth, remote, 0, 0, sftpWriteThunk, sftpProgressThunk, box)
        }
    }

    /// Upload a local file to a remote path, reporting (bytesSoFar, total).
    public func upload(localURL: URL, remote: String,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SFTPError(kind: .io, message: "Could not open the local file for reading")
        }
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        // A local read that *throws* must not be folded into the `return 0` that
        // signals a clean EOF — the C upload loop would treat it as end-of-file,
        // truncate-write only the bytes sent so far, and report success. Capture
        // the error and return -1 so the transfer aborts and surfaces it.
        let readError = ReadErrorBox()
        let ctx = TransferContext(
            onWrite: { _ in true },
            onProgress: { total, sofar in progress(sofar, total); return true },
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
            _ = try await runTransfer(ctx) { auth, box in
                gsb_upload(auth, remote, total, 0, sftpReadThunk, sftpProgressThunk, box)
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

    // MARK: Streaming download (for the queued-download engine)

    /// Low-level resumable download. The caller's `write` returns false to fail,
    /// `progress` returns false to abort (pause/cancel). Never throws — inspect
    /// the returned result. Learns the host key on first connect.
    public func streamingDownload(remote: String, resumeFrom: Int64, maxBytesPerSecond: Int64,
                                  write: @escaping @Sendable (UnsafeRawBufferPointer) -> Bool,
                                  progress: @escaping @Sendable (Int64, Int64) -> Bool) async -> SFTPResult {
        let ctx = TransferContext(onWrite: write, onProgress: progress, onRead: nil)
        let expected = hostKeys.fingerprint(host: target.host, port: target.port)
        let result = await withCheckedContinuation { (cont: CheckedContinuation<GSBResult, Never>) in
            let box = Unmanaged.passRetained(ctx)
            let thread = Thread {
                let r = Self.withAuth(self.target, expected: expected) { auth in
                    gsb_download(auth, remote, resumeFrom, maxBytesPerSecond,
                                 sftpWriteThunk, sftpProgressThunk, box.toOpaque())
                }
                box.release()
                cont.resume(returning: r)
            }
            thread.name = "goel.sftp-transfer"
            thread.stackSize = 1 << 20
            thread.start()
        }
        learnIfNeeded(expected: expected, result: result)
        return SFTPResult(result)
    }

    // MARK: Plumbing

    /// Run a session-scoped op on a dedicated thread; throw on failure and pin
    /// the host key on first successful connect.
    private func run(_ body: @escaping @Sendable (UnsafePointer<GSBAuth>) -> GSBResult) async throws -> GSBResult {
        let expected = hostKeys.fingerprint(host: target.host, port: target.port)
        let result = await withCheckedContinuation { (cont: CheckedContinuation<GSBResult, Never>) in
            let thread = Thread {
                let r = Self.withAuth(self.target, expected: expected, body)
                cont.resume(returning: r)
            }
            thread.name = "goel.sftp-op"
            thread.stackSize = 1 << 20
            thread.start()
        }
        learnIfNeeded(expected: expected, result: result)
        guard result.code == GSB_OK else { throw SFTPResult(result).asError }
        return result
    }

    private func runTransfer(_ ctx: TransferContext,
                             _ body: @escaping @Sendable (UnsafePointer<GSBAuth>, UnsafeMutableRawPointer) -> GSBResult) async throws -> GSBResult {
        let expected = hostKeys.fingerprint(host: target.host, port: target.port)
        let result = await withCheckedContinuation { (cont: CheckedContinuation<GSBResult, Never>) in
            let box = Unmanaged.passRetained(ctx)
            let thread = Thread {
                let r = Self.withAuth(self.target, expected: expected) { auth in
                    body(auth, box.toOpaque())
                }
                box.release()
                cont.resume(returning: r)
            }
            thread.name = "goel.sftp-transfer"
            thread.stackSize = 1 << 20
            thread.start()
        }
        learnIfNeeded(expected: expected, result: result)
        guard result.code == GSB_OK else { throw SFTPResult(result).asError }
        return result
    }

    /// On a first, un-pinned connect (`expected == nil`) that succeeded far
    /// enough to read the host key, remember it so later connects are pinned.
    private func learnIfNeeded(expected: String?, result: GSBResult) {
        guard expected == nil else { return }
        let fp = withUnsafeBytes(of: result.fingerprint) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        guard !fp.isEmpty, result.code != GSB_ERR_RESOLVE,
              result.code != GSB_ERR_CONNECT, result.code != GSB_ERR_HANDSHAKE else { return }
        hostKeys.setFingerprint(fp, host: target.host, port: target.port)
    }

    /// Marshal a target + optional pinned fingerprint into a `GSBAuth` with
    /// correct C-string lifetimes, and invoke `body`.
    private static func withAuth(_ t: SFTPTarget, expected: String?,
                                 _ body: (UnsafePointer<GSBAuth>) -> GSBResult) -> GSBResult {
        func withOptCString(_ s: String?, _ f: (UnsafePointer<CChar>?) -> GSBResult) -> GSBResult {
            if let s { return s.withCString(f) }
            return f(nil)
        }
        return t.host.withCString { host in
            t.username.withCString { user in
                withOptCString(t.password) { pass in
                    withOptCString(expected) { fp in
                        var auth = GSBAuth(host: host, port: Int32(t.port), username: user,
                                           password: pass, use_agent: t.useAgent ? 1 : 0,
                                           expected_fp: fp)
                        return withUnsafePointer(to: &auth) { body($0) }
                    }
                }
            }
        }
    }
}

/// A Swift view of a `GSBResult`.
public struct SFTPResult: Sendable {
    public let code: Int32
    public let value: Int64
    public let fingerprint: String
    public let message: String

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
        case Int(GSB_ERR_STAT): kind = .stat
        default: kind = .unknown
        }
        return SFTPError(kind: kind, message: message.isEmpty ? "SFTP error \(code)" : message)
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
                            isDir: Int32, size: Int64, mtime: Int64, perms: UInt) {
    guard let ud, let name else { return }
    let collector = Unmanaged<ListCollector>.fromOpaque(ud).takeUnretainedValue()
    let entry = SFTPEntry(name: String(cString: name),
                          isDirectory: isDir != 0,
                          size: size,
                          modified: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil,
                          permissions: UInt32(truncatingIfNeeded: perms))
    collector.entries.append(entry)
}
