import Foundation
import CurlBridge

enum BoundHTTPClient {

    struct Request: Sendable {
        var url: URL
        var rangeStart: Int64
        var rangeEnd: Int64       // inclusive
        var interfaceName: String // BSD name; empty = no bind
        var userAgent: String
        var referer: String?
        var authorization: String?
        var extraHeaders: [String: String]
        var connectTimeout: Double
        /// When > 0, CurlBridge aborts before writing a body whose Content-Range total differs.
        var expectedTotal: Int64?
        /// Strong validator: a changed entity then answers 200, never a 206 spliced from another version.
        var ifRange: String? = nil
    }

    struct Response: Sendable {
        var curlCode: Int
        var httpStatus: Int
        var contentRangeTotal: Int64?
        var bytesWritten: Int64
        var aborted: Bool
        var rangeTotalMismatch: Bool
        /// Server answered a ranged request with a final 200; C aborted before the first body byte.
        var rangeIgnored: Bool = false
        var etag: String? = nil
        var lastModified: String? = nil
        /// The 206 started somewhere other than `rangeStart`; C refused the body.
        var rangeMismatch: Bool = false
        /// A LOCAL write failed: the NIC is healthy, so this must never demote it or be retried as network.
        var writeFailure: DownloadError? = nil
    }

    /// `@unchecked Sendable`: body writes run on the curl thread, `abort` may flip from any thread.
    final class TransferContext: @unchecked Sendable {
        let handle: FileHandle
        let limiter: RateLimiter?
        let onBytes: (@Sendable (Int) -> Void)?
        let shouldAbort: (@Sendable () -> Bool)?
        private let lock = NSLock()
        private var _aborted = false
        private var _writeFailure: DownloadError?
        /// Coalesce RateLimiter hops — Task-per-write thrashes under multi-path.
        private var pendingPace = 0
        private static let paceBatch = 64 * 1024

        init(handle: FileHandle, limiter: RateLimiter?,
             onBytes: (@Sendable (Int) -> Void)? = nil,
             shouldAbort: (@Sendable () -> Bool)? = nil) {
            self.handle = handle
            self.limiter = limiter
            self.onBytes = onBytes
            self.shouldAbort = shouldAbort
        }

        var aborted: Bool {
            lock.lock(); defer { lock.unlock() }
            return _aborted || (shouldAbort?() ?? false)
        }

        func abort() {
            lock.lock(); _aborted = true; lock.unlock()
        }

        var writeFailure: DownloadError? {
            lock.lock(); defer { lock.unlock() }
            return _writeFailure
        }

        func recordWriteFailure(_ error: Error) {
            let mapped = SegmentedTransfer.diskFullError(error)
                ?? DownloadError.unknown("Couldn't write to disk: \((error as NSError).localizedDescription)")
            lock.lock(); _writeFailure = mapped; lock.unlock()
        }

        func paceIfNeeded(_ size: Int, force: Bool = false) {
            guard let limiter, !limiter.isEffectivelyUnlimited else { return }
            lock.lock()
            pendingPace += size
            let n = pendingPace
            let fire = force ? n > 0 : n >= Self.paceBatch
            if fire { pendingPace = 0 }
            lock.unlock()
            guard fire, n > 0 else { return }
            let sem = DispatchSemaphore(value: 0)
            let paceTask = Task {
                await limiter.pace(n)
                sem.signal()
            }
            // Poll, don't cap: a hard timeout let curl outrun the limit, and a long wait blocked pause/remove.
            while sem.wait(timeout: .now() + 0.2) == .timedOut {
                if aborted { paceTask.cancel(); return }
            }
        }
    }

    static func downloadRange(
        _ request: Request,
        file: FileHandle,
        fileOffset: UInt64,
        limiter: RateLimiter?,
        onBytes: (@Sendable (Int) -> Void)? = nil,
        shouldAbort: (@Sendable () -> Bool)? = nil
    ) async -> Response {
        let ctx = TransferContext(handle: file, limiter: limiter, onBytes: onBytes,
                                  shouldAbort: shouldAbort)
        do {
            try file.seek(toOffset: fileOffset)
        } catch {
            return Response(curlCode: -1, httpStatus: 0, contentRangeTotal: nil,
                            bytesWritten: 0, aborted: false, rangeTotalMismatch: false)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Response, Never>) in
                let box = Unmanaged.passRetained(ctx)
                let req = request
                let thread = Thread {
                    let result = Self.performBlocking(req, contextBox: box)
                    cont.resume(returning: result)
                }
                thread.name = "goel.http-bound"
                thread.stackSize = 1 << 20
                thread.start()
            }
        } onCancel: {
            ctx.abort()
        }
    }

    private static func performBlocking(
        _ request: Request,
        contextBox: Unmanaged<TransferContext>
    ) -> Response {
        let context = contextBox.toOpaque()
        defer { contextBox.release() }

        // The C side splits on "\n", so a CR/LF inside a value would smuggle in a header of its own.
        let extra = request.extraHeaders
            .filter { SegmentedTransfer.isSafeHeader(name: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")

        let timeout = max(1, Int(request.connectTimeout.rounded(.up)))
        let url = request.url.absoluteString
        let ifname = request.interfaceName
        let ua = request.userAgent
        let ref = request.referer ?? ""
        let auth = request.authorization ?? ""
        let ifRange = request.ifRange ?? ""

        let expected = request.expectedTotal ?? 0
        let ctx = contextBox.takeUnretainedValue()
        let raw: GCBHTTPResult = url.withCString { urlC in
            ifname.withCString { ifC in
                ua.withCString { uaC in
                    ref.withCString { refC in
                        auth.withCString { authC in
                            extra.withCString { extraC in
                                ifRange.withCString { ifRangeC in
                                    gcb_http_range(
                                        urlC,
                                        request.rangeStart,
                                        request.rangeEnd,
                                        ifname.isEmpty ? nil : ifC,
                                        uaC,
                                        ref.isEmpty ? nil : refC,
                                        auth.isEmpty ? nil : authC,
                                        extra.isEmpty ? nil : extraC,
                                        ifRange.isEmpty ? nil : ifRangeC,
                                        timeout,
                                        0,
                                        expected,
                                        boundWriteThunk,
                                        boundProgressThunk,
                                        context
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        // Drain any residual paced bytes so the last <64 KiB is still limited.
        ctx.paceIfNeeded(0, force: true)

        let total: Int64? = raw.content_range_total > 0 ? raw.content_range_total : nil
        return Response(
            curlCode: Int(raw.code),
            httpStatus: Int(raw.http_status),
            contentRangeTotal: total,
            bytesWritten: raw.bytes_written,
            aborted: gcb_is_aborted(raw.code) != 0 || ctx.aborted,
            rangeTotalMismatch: raw.range_total_mismatch != 0,
            rangeIgnored: raw.range_ignored != 0,
            etag: Self.cString(raw.etag),
            lastModified: Self.cString(raw.last_modified),
            rangeMismatch: raw.range_mismatch != 0,
            writeFailure: ctx.writeFailure
        )
    }

    private static func cString<T>(_ tuple: T) -> String? {
        withUnsafeBytes(of: tuple) { buf in
            guard let base = buf.baseAddress else { return nil }
            let s = String(cString: base.assumingMemoryBound(to: CChar.self))
            return s.isEmpty ? nil : s
        }
    }
}

private func boundWriteThunk(_ data: UnsafePointer<CChar>?, _ size: Int, _ userdata: UnsafeMutableRawPointer?) -> Int {
    guard let data, let userdata, size > 0 else { return size }
    let ctx = Unmanaged<BoundHTTPClient.TransferContext>.fromOpaque(userdata).takeUnretainedValue()
    if ctx.aborted { return 0 }

    do {
        try ctx.handle.write(contentsOf: UnsafeRawBufferPointer(start: data, count: size))
        ctx.onBytes?(size)
        ctx.paceIfNeeded(size)
        return size
    } catch {
        ctx.recordWriteFailure(error)
        return 0
    }
}

private func boundProgressThunk(_ userdata: UnsafeMutableRawPointer?, _ dltotal: Int64, _ dlnow: Int64) -> Int32 {
    guard let userdata else { return 1 }
    let ctx = Unmanaged<BoundHTTPClient.TransferContext>.fromOpaque(userdata).takeUnretainedValue()
    return ctx.aborted ? 1 : 0
}
