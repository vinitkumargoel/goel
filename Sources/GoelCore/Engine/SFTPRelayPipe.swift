import Foundation

/// `@unchecked Sendable`: every field is touched only under `condition`.
final class SFTPRelayPipe: @unchecked Sendable {

    /// The bound is what makes a stalled destination cost bounded memory with several copies running.
    static let defaultCapacity = 8 * 1024 * 1024

    private let capacity: Int
    private let condition = NSCondition()

    private var chunks: [[UInt8]] = []
    private var head = 0
    private var buffered = 0

    private var producerDone = false
    /// Once set, both sides must unblock and report failure — a copy must never half-succeed silently.
    private var failure: String?

    init(capacity: Int = SFTPRelayPipe.defaultCapacity) {
        self.capacity = max(64 * 1024, capacity)
    }

    /// False means the consumer failed or went away: the caller must abort the download, not treat it as a short write.
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

    /// Returns the byte count, 0 at clean end-of-stream, or -1 on failure — the contract `gsb_upload`'s read callback expects.
    func read(into buf: UnsafeMutableRawBufferPointer) -> Int {
        guard !buf.isEmpty else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty && !producerDone && failure == nil {
            condition.wait()
        }
        if failure != nil { return -1 }
        guard !chunks.isEmpty else { return 0 }

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

    func finish() {
        condition.lock()
        producerDone = true
        condition.broadcast()
        condition.unlock()
    }

    /// The first reason recorded wins: a failure on one side usually provokes a vaguer one on the other.
    func fail(_ reason: String) {
        condition.lock()
        if failure == nil { failure = reason }
        chunks.removeAll()
        head = 0
        buffered = 0
        condition.broadcast()
        condition.unlock()
    }

    var failureReason: String? {
        condition.lock(); defer { condition.unlock() }
        return failure
    }
}
