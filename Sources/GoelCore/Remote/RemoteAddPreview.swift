import Foundation

/// A backend that can look at links before they are queued: `/api/add-preview`. A separate protocol
/// so older conformers (and test fakes) need not grow it; the route answers 404 without one.
public protocol RemoteAddPreviewing: AnyObject, Sendable {
    /// What the source is, as far as the engine can tell without starting it.
    func previewAdd(_ source: DownloadSource, saveDirectory: String?) async -> DownloadPreview
    /// Bytes free on the volume a download into `saveDirectory` (nil = the default) would land on.
    func freeBytes(forSaveDirectory saveDirectory: String?) async -> Int64?
}

extension DownloadManager: RemoteAddPreviewing {
    public func previewAdd(_ source: DownloadSource, saveDirectory: String?) async -> DownloadPreview {
        await resolveMetadata(for: source, saveDirectory: remoteSaveDirectory(saveDirectory))
    }

    public func freeBytes(forSaveDirectory saveDirectory: String?) async -> Int64? {
        let folder = remoteSaveDirectory(saveDirectory) ?? settings.defaultSaveDirectory
        // Off the actor: a network mount can take seconds to answer statfs.
        return await Task.detached(priority: .userInitiated) {
            RemoteAddPreview.availableBytes(near: folder)
        }.value
    }
}

enum RemoteAddPreview {
    static let path = "/api/add-preview"
    /// Lines past this are listed as unchecked: each one costs a DNS lookup and a probe.
    static let maxChecked = 50
    /// Every non-blank line counts, refused or not: screening alone is a serial DNS lookup each.
    /// Past this, lines are not even parsed.
    static let maxLines = 200
    /// Previews running at once across the whole server; more are answered 429.
    static let maxInFlight = 2
    /// Shown instead of the engine's own wording, which can carry a system error verbatim.
    static let unresolvedNote = "Couldn’t check this link; it can still be added."
    static let busyMessage = "Still checking other links — try again in a moment."

    static let gate = InFlightGate(limit: maxInFlight)
    /// A probe that has not answered by then is reported unresolved; the add still works.
    static let deadline: Duration = .seconds(8)
    static let maxFiles = 200

    struct Payload: Decodable {
        var url: String
        var folder: String?
    }

    struct File: Encodable, Equatable {
        var name: String
        var size: Int64
    }

    /// One pasted line. `index` points into the lines the client sent, so no link is echoed back.
    struct Item: Encodable, Equatable {
        var index: Int
        var status: String
        var name: String?
        var kind: String?
        var totalBytes: Int64?
        var estimated: Bool
        var files: [File]
        var fileCount: Int
        var note: String?
    }

    struct Response: Encodable {
        var items: [Item]
        var freeBytes: Int64?
    }

    /// The nearest existing ancestor's volume: a "sort by type" subfolder may not exist yet.
    static func availableBytes(near folder: String) -> Int64? {
        var path = (folder as NSString).standardizingPath
        let fm = FileManager.default
        while !fm.fileExists(atPath: path), path != "/", !path.isEmpty {
            path = (path as NSString).deletingLastPathComponent
        }
        #if os(Linux)
        let attrs = try? fm.attributesOfFileSystem(forPath: path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
        #else
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #endif
    }

    /// Runs `work` but gives up after `deadline`, cancelling it: a metadata fetch that honours
    /// cancellation stops there instead of running on unobserved.
    static func withDeadline<T: Sendable>(_ deadline: Duration,
                                          _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.arm(continuation)
            let job: Task<Void, Never> = Task { once.resume(await work()) }
            Task {
                try? await Task.sleep(for: deadline)
                if once.resume(nil) { job.cancel() }
            }
        }
    }
}

/// A counter of running requests with a ceiling, shared by every connection.
final class InFlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// False when `limit` are already running; otherwise the caller must `leave()`.
    func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running >= limit { return false }
        running += 1
        return true
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        running = max(0, running - 1)
    }
}

/// A continuation that the first of several racers resumes; later resumes are dropped.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func arm(_ c: CheckedContinuation<T, Never>) {
        lock.lock(); defer { lock.unlock() }
        continuation = c
    }

    /// True when this call was the one that resumed.
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}

extension RemoteRouter {
    /// `POST /api/add-preview`: what each pasted line would queue, without queueing it. Same refusals
    /// as `/api/add` — inline credentials, unparseable lines, internal-network targets — so the review
    /// can show them before the user commits, and a probe never goes where an add could not.
    static func addPreview(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let previewer = backend as? RemoteAddPreviewing else {
            return notFound("This server can’t check links before adding them.")
        }
        guard let payload = try? JSONDecoder().decode(RemoteAddPreview.Payload.self, from: request.body)
        else { return badRequest() }
        guard RemoteAddPreview.gate.enter() else {
            let body = Data("\(RemoteAddPreview.busyMessage)\n".utf8)
            return response(status: "429 Too Many Requests", type: "text/plain", body: body,
                            extraHeaders: ["Retry-After": "2"])
        }
        defer { RemoteAddPreview.gate.leave() }
        return await previewResponse(payload, backend: backend, previewer: previewer)
    }

    private static func previewResponse(_ payload: RemoteAddPreview.Payload, backend: RemoteBackend,
                                        previewer: RemoteAddPreviewing) async -> Data {
        let folder = payload.folder?.trimmingCharacters(in: .whitespaces)
        let saveDirectory = (folder?.isEmpty == false) ? folder : nil
        if let saveDirectory, await backend.remoteSaveDirectoryAllowed(saveDirectory) == false {
            return forbidden(saveFolderRefusal)
        }

        let lines = payload.url.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        // Blank lines stay in: `index` must count the same lines the client split.
        let existing = Set(await backend.taskSnapshot().map(\.source.locator))
        let viaProxy = await backend.remoteAddResolvesThroughProxy()

        var items: [RemoteAddPreview.Item?] = Array(repeating: nil, count: lines.count)
        var toProbe: [(Int, DownloadSource)] = []
        var seen = 0
        for (index, line) in lines.enumerated() where !line.isEmpty {
            seen += 1
            if seen > RemoteAddPreview.maxLines {
                items[index] = .init(index: index, status: "unchecked", estimated: false,
                                     files: [], fileCount: 0, note: nil)
                continue
            }
            if DownloadSource.parseWithCredentials(line)?.authorization != nil {
                items[index] = .init(index: index, status: "credentials", estimated: false,
                                     files: [], fileCount: 0, note: inlineCredentialsRefusal)
                continue
            }
            guard let source = DownloadSource.parse(line) else {
                items[index] = .init(index: index, status: "unsupported", estimated: false,
                                     files: [], fileCount: 0, note: nil)
                continue
            }
            if existing.contains(source.locator) {
                items[index] = .init(index: index, status: "duplicate", name: nil,
                                     kind: source.kind.rawValue, estimated: false,
                                     files: [], fileCount: 0, note: nil)
                continue
            }
            if toProbe.count >= RemoteAddPreview.maxChecked {
                items[index] = .init(index: index, status: "unchecked", name: nil,
                                     kind: source.kind.rawValue, estimated: false,
                                     files: [], fileCount: 0, note: nil)
                continue
            }
            let screened = await NetworkGuard.screen(sources: [source], resolvedByProxy: viaProxy)
            if screened.allowed.isEmpty {
                items[index] = .init(index: index, status: "refused", name: nil,
                                     kind: source.kind.rawValue, estimated: false,
                                     files: [], fileCount: 0, note: nil)
                continue
            }
            toProbe.append((index, source))
        }

        await withTaskGroup(of: RemoteAddPreview.Item.self) { group in
            for (index, source) in toProbe {
                group.addTask {
                    let preview = await RemoteAddPreview.withDeadline(RemoteAddPreview.deadline) {
                        await previewer.previewAdd(source, saveDirectory: saveDirectory)
                    }
                    return previewItem(index: index, source: source, preview: preview)
                }
            }
            for await item in group { items[item.index] = item }
        }

        let free = await previewer.freeBytes(forSaveDirectory: saveDirectory)
        return json(RemoteAddPreview.Response(items: items.compactMap { $0 }, freeBytes: free))
    }

    static func previewItem(index: Int, source: DownloadSource,
                            preview: DownloadPreview?) -> RemoteAddPreview.Item {
        guard let preview else {
            return .init(index: index, status: "ok", name: nil, kind: source.kind.rawValue,
                         estimated: false, files: [], fileCount: 0, note: nil)
        }
        let files = preview.files.prefix(RemoteAddPreview.maxFiles)
            .map { RemoteAddPreview.File(name: $0.path, size: $0.length) }
        return .init(index: index, status: "ok", name: preview.suggestedName,
                     kind: preview.kind.rawValue, totalBytes: preview.totalBytes,
                     estimated: preview.isEstimatedSize, files: Array(files),
                     fileCount: preview.files.count,
                     note: preview.note == nil ? nil : RemoteAddPreview.unresolvedNote)
    }
}
