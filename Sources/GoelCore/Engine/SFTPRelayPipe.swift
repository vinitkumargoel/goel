import Foundation

/// Bounded byte pipe joining two blocking libssh2 threads (download writes, upload reads): SFTP has no
/// server-side copy; the `capacity` bound backpressures a fast source. Sendable: all state under `condition`.
final class SFTPRelayPipe: @unchecked Sendable {

    /// Bytes allowed in the pipe before the source waits: absorbs ordinary two-network jitter, yet
    /// a stalled destination costs bounded memory even with several copies running.
    static let defaultCapacity = 8 * 1024 * 1024

    private let capacity: Int
    private let condition = NSCondition()

    /// Chunks in arrival order. `head` is how far into `chunks.first` the reader
    /// has already consumed, so a partially-read chunk is never copied again.
    private var chunks: [[UInt8]] = []
    private var head = 0
    private var buffered = 0

    private var producerDone = false
    /// Set when either side gives up. Once set, both sides unblock and report
    /// failure — a copy must never half-succeed silently.
    private var failure: String?

    init(capacity: Int = SFTPRelayPipe.defaultCapacity) {
        self.capacity = max(64 * 1024, capacity)
    }

    /// Hand `buf` to the pipe, blocking while full. Returns false when the consumer failed or went
    /// away — the caller must abort the download, not treat it as a short write.
    func write(_ buf: UnsafeRawBufferPointer) -> Bool {
        guard !buf.isEmpty else { return true }
        condition.lock()
        defer { condition.unlock() }
        while buffered >= capacity && failure == nil {
            condition.wait()
        }
        guard failure == nil else { return false }
        chunks.append(Array(buf))
        buffered += buf.count
        condition.broadcast()
        return true
    }

    /// Fill `buf` with what's available, blocking until there is something. Returns the byte count,
    /// 0 at clean end-of-stream, or -1 on failure — the contract `gsb_upload`'s read callback expects.
    func read(into buf: UnsafeMutableRawBufferPointer) -> Int {
        guard !buf.isEmpty else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty && !producerDone && failure == nil {
            condition.wait()
        }
        if failure != nil { return -1 }
        guard !chunks.isEmpty else { return 0 }   // producer finished and drained

        var written = 0
        while written < buf.count, let chunk = chunks.first {
            let available = chunk.count - head
            let take = min(available, buf.count - written)
            chunk.withUnsafeBytes { raw in
                let source = UnsafeRawBufferPointer(rebasing: raw[head..<(head + take)])
                buf.baseAddress!.advanced(by: written).copyMemory(from: source.baseAddress!,
                                                                 byteCount: take)
            }
            written += take
            head += take
            if head == chunk.count {
                chunks.removeFirst()
                head = 0
            }
        }
        buffered -= written
        condition.broadcast()
        return written
    }

    /// The source has sent its last byte. The reader drains what remains and then
    /// sees end-of-stream.
    func finish() {
        condition.lock()
        producerDone = true
        condition.broadcast()
        condition.unlock()
    }

    /// Abandon the copy; both halves unblock. The first reason recorded wins — a failure on one side
    /// usually provokes a vaguer one on the other.
    func fail(_ reason: String) {
        condition.lock()
        if failure == nil { failure = reason }
        // Drop what is buffered so a blocked writer isn't holding memory nobody
        // will ever read.
        chunks.removeAll()
        head = 0
        buffered = 0
        condition.broadcast()
        condition.unlock()
    }

    /// The recorded failure, if the copy was abandoned.
    var failureReason: String? {
        condition.lock(); defer { condition.unlock() }
        return failure
    }
}
