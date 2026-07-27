import Foundation

/// A bounded byte pipe joining two blocking libssh2 loops running on different
/// threads: a download writing into it, an upload reading out of it.
///
/// SFTP has no server-side copy, so a remote→remote copy has to move the bytes
/// through this machine. Doing that through a temporary file would mean paying
/// disk for every byte and waiting for the whole download before the upload could
/// start; streaming means the two halves overlap and nothing is ever spooled.
///
/// The bound is what makes it safe: the writer blocks once `capacity` bytes are
/// buffered, so a fast source copying to a slow destination cannot grow the
/// buffer without limit. That backpressure is the entire reason this type exists
/// rather than an unbounded queue.
///
/// `@unchecked Sendable`: every stored property is read and written only under
/// `condition`.
final class SFTPRelayPipe: @unchecked Sendable {

    /// How many bytes may sit in the pipe before the source is made to wait.
    /// Large enough to absorb ordinary jitter between two networks, small enough
    /// that a stalled destination costs bounded memory even with several copies
    /// running at once.
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

    /// Hand `buf` to the pipe, blocking while it is full. Returns false when the
    /// consumer has failed or gone away, which the caller must translate into
    /// aborting the download rather than treating as a short write.
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

    /// Fill `buf` with whatever is available, blocking until there is something to
    /// give. Returns the byte count, 0 at clean end-of-stream, or -1 on failure —
    /// the contract `gsb_upload`'s read callback expects.
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

    /// Abandon the copy. Both halves unblock; the first reason recorded is the one
    /// reported, since a failure on one side usually provokes a vaguer one on the
    /// other.
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
