import Foundation
import CurlBridge

/// Blocking HTTP(S) ranged GET pinned to a network interface via CurlBridge
/// (`IP_BOUND_IF` / `SO_BINDTODEVICE`). Runs on a dedicated thread — never the
/// cooperative pool — matching ``FTPEngine``.
///
/// Aggregate rate limiting is applied via Swift ``RateLimiter`` (curl's own
/// per-handle cap stays 0) so N multi-path handles do not N× the user cap.
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
        /// When > 0, CurlBridge requires Content-Range total to match and aborts
        /// before writing a mismatched body.
        var expectedTotal: Int64?
    }

    struct Response: Sendable {
        var curlCode: Int
        var httpStatus: Int
        var contentRangeTotal: Int64?
        var bytesWritten: Int64
        var aborted: Bool
        var rangeTotalMismatch: Bool
    }

    /// Context shared with C write/progress callbacks. `@unchecked Sendable` —
    /// body writes run on the curl thread; `abort` may flip from any thread.
    final class TransferContext: @unchecked Sendable {
        let handle: FileHandle
        let limiter: RateLimiter?
        let onBytes: (@Sendable (Int) -> Void)?
        private let lock = NSLock()
        private var _aborted = false
        private var _written: Int64 = 0

        init(handle: FileHandle, limiter: RateLimiter?,
             onBytes: (@Sendable (Int) -> Void)? = nil) {
            self.handle = handle
            self.limiter = limiter
            self.onBytes = onBytes
        }

        var aborted: Bool {
            lock.lock(); defer { lock.unlock() }
            return _aborted
        }

        func abort() {
            lock.lock(); _aborted = true; lock.unlock()
        }

        var written: Int64 {
            lock.lock(); defer { lock.unlock() }
            return _written
        }

        func addWritten(_ n: Int64) {
            lock.lock(); _written += n; lock.unlock()
        }
    }

    /// Run a ranged GET on a dedicated thread, writing at `fileOffset`.
    static func downloadRange(
        _ request: Request,
        file: FileHandle,
        fileOffset: UInt64,
        limiter: RateLimiter?,
        onBytes: (@Sendable (Int) -> Void)? = nil
    ) async -> Response {
        let ctx = TransferContext(handle: file, limiter: limiter, onBytes: onBytes)
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

        let extra = request.extraHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")

        let timeout = max(1, Int(request.connectTimeout.rounded(.up)))
        let url = request.url.absoluteString
        let ifname = request.interfaceName
        let ua = request.userAgent
        let ref = request.referer ?? ""
        let auth = request.authorization ?? ""

        let expected = request.expectedTotal ?? 0
        let raw: GCBHTTPResult = url.withCString { urlC in
            ifname.withCString { ifC in
                ua.withCString { uaC in
                    ref.withCString { refC in
                        auth.withCString { authC in
                            extra.withCString { extraC in
                                gcb_http_range(
                                    urlC,
                                    request.rangeStart,
                                    request.rangeEnd,
                                    ifname.isEmpty ? nil : ifC,
                                    uaC,
                                    ref.isEmpty ? nil : refC,
                                    auth.isEmpty ? nil : authC,
                                    extra.isEmpty ? nil : extraC,
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

        let total: Int64? = raw.content_range_total > 0 ? raw.content_range_total : nil
        let ctx = contextBox.takeUnretainedValue()
        return Response(
            curlCode: Int(raw.code),
            httpStatus: Int(raw.http_status),
            contentRangeTotal: total,
            bytesWritten: raw.bytes_written,
            aborted: gcb_is_aborted(raw.code) != 0 || ctx.aborted,
            rangeTotalMismatch: raw.range_total_mismatch != 0
        )
    }
}

// MARK: - C thunks

private func boundWriteThunk(_ data: UnsafePointer<CChar>?, _ size: Int, _ userdata: UnsafeMutableRawPointer?) -> Int {
    guard let data, let userdata, size > 0 else { return size }
    let ctx = Unmanaged<BoundHTTPClient.TransferContext>.fromOpaque(userdata).takeUnretainedValue()
    if ctx.aborted { return 0 }

    let buffer = Data(bytes: data, count: size)
    do {
        try ctx.handle.write(contentsOf: buffer)
        ctx.addWritten(Int64(size))
        ctx.onBytes?(size)
        if let limiter = ctx.limiter {
            let sem = DispatchSemaphore(value: 0)
            Task {
                await limiter.pace(size)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 60)
        }
        return size
    } catch {
        return 0
    }
}

private func boundProgressThunk(_ userdata: UnsafeMutableRawPointer?, _ dltotal: Int64, _ dlnow: Int64) -> Int32 {
    guard let userdata else { return 1 }
    let ctx = Unmanaged<BoundHTTPClient.TransferContext>.fromOpaque(userdata).takeUnretainedValue()
    return ctx.aborted ? 1 : 0
}
