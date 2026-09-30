import Foundation

/// Shared by every SSE client of one server: an idle 2,000-task queue used to be re-encoded per
/// client per tick. Rows are hashed (cheap) and only a changed hash pays for JSON encoding.
final class RemoteEventFrameCache: @unchecked Sendable {

    struct Frame: Equatable {
        let hash: Int
        let data: Data
    }

    private let lock = NSLock()
    private var cached: Frame?

    /// nil when the rows cannot be encoded (a non-finite speed): skip the tick, never blank the list.
    func frame(for tasks: [DownloadTask]) -> Frame? {
        let rows = tasks.map(RemoteRouter.TaskRow.init)
        var hasher = Hasher()
        hasher.combine(rows)
        let hash = hasher.finalize()
        lock.lock()
        if let cached, cached.hash == hash { lock.unlock(); return cached }
        lock.unlock()
        guard let data = RemoteRouter.encodeEventFrame(rows) else { return nil }
        let frame = Frame(hash: hash, data: data)
        lock.lock(); cached = frame; lock.unlock()
        return frame
    }
}

/// Per-connection send decision: unchanged frames are skipped, but a comment line goes out often
/// enough that proxies keep the stream open and a vanished client is noticed by a failed write.
struct RemoteEventPacer {
    static let keepAliveInterval: TimeInterval = 15
    static let keepAliveFrame = Data(": keep-alive\n\n".utf8)

    private(set) var lastHash: Int?
    private(set) var lastSend: Date?

    enum Action: Equatable {
        case send(Data)
        case keepAlive
        case skip
    }

    mutating func next(_ frame: RemoteEventFrameCache.Frame?, now: Date = Date()) -> Action {
        if let frame, frame.hash != lastHash {
            lastHash = frame.hash
            lastSend = now
            return .send(frame.data)
        }
        if let lastSend, now.timeIntervalSince(lastSend) < Self.keepAliveInterval { return .skip }
        lastSend = now
        return .keepAlive
    }

    /// What goes on the wire for an action; nil = nothing to send this tick.
    static func payload(_ action: Action) -> Data? {
        switch action {
        case .send(let data): return data
        case .keepAlive: return keepAliveFrame
        case .skip: return nil
        }
    }
}
