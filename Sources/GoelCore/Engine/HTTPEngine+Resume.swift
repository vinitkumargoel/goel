import Foundation

// MARK: - Resume cursor

/// The resumable-download cursor: the on-disk record of which byte ranges are
/// complete, gated by `ETag` / `Last-Modified` validators so a changed remote
/// file restarts rather than corrupts. Split out of ``HTTPEngine`` so the
/// transfer paths stay focused on moving bytes.
extension HTTPEngine {

    struct Range64: Codable, Sendable {
        var start: Int64
        var end: Int64
    }

    struct CursorMeta {
        var etag: String?
        var lastModified: String?
        var total: Int64
        var ranges: [Range64]
    }

    struct ResumeCursor: Codable, Sendable {
        var etag: String?
        var lastModified: String?
        var totalBytes: Int64
        var ranges: [Range64]
        var completed: [Int64]
    }

    func maybeEmitResume(_ id: UUID, now: Date) {
        guard cursorMeta[id] != nil else { return }
        if now.timeIntervalSince(lastResumeEmit[id] ?? .distantPast) < 1.0 { return }
        lastResumeEmit[id] = now
        if let data = buildResumeData(id) {
            tasks[id]?.resumeData = data
            emit(id, .resumeDataUpdated(data))
        }
    }

    /// `internal` so `pause()` (in `HTTPEngine.swift`) can snapshot resume data.
    func buildResumeData(_ id: UUID) -> Data? {
        guard let meta = cursorMeta[id] else { return nil }
        let completed = meta.ranges.indices.map { segmentBytes[id]?[$0] ?? 0 }
        let cursor = ResumeCursor(
            etag: meta.etag,
            lastModified: meta.lastModified,
            totalBytes: meta.total,
            ranges: meta.ranges,
            completed: completed
        )
        return try? JSONEncoder().encode(cursor)
    }

    func validatorsMatch(_ cursor: ResumeCursor, _ probe: ProbeResult) -> Bool {
        Self.validatorsAllowResume(
            cursorETag: cursor.etag, cursorLastModified: cursor.lastModified,
            probeETag: probe.etag, probeLastModified: probe.lastModified
        )
    }

    /// Pure, testable resume-validation gate. If neither side offers an `ETag`
    /// nor a `Last-Modified`, there is nothing to verify the remote file is
    /// unchanged — so we DO NOT resume (a silent swap would corrupt the file);
    /// we restart from scratch instead.
    static func validatorsAllowResume(
        cursorETag: String?, cursorLastModified: String?,
        probeETag: String?, probeLastModified: String?
    ) -> Bool {
        if let a = cursorETag, let b = probeETag { return a == b }
        if let a = cursorLastModified, let b = probeLastModified { return a == b }
        return false
    }
}
