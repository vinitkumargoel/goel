import Foundation

// Domain object → wire DTO mapping. Lives in GoelCore (not GoelContracts) on purpose:
// building a `Wire.TaskRow` needs engine-side services — `RemoteStreamService`'s
// on-disk stream probe and `RemoteRouter`'s enum→token helpers — that must not leak
// into the platform-free contract. Each initializer delegates to the contract's
// public memberwise init, so the contract stays a pure shape.

extension Wire.TaskRow {
    init(_ task: DownloadTask) {
        self.init(
            id: task.id.uuidString,
            name: task.name,
            status: task.status.displayName,
            statusToken: RemoteRouter.statusToken(task.status),
            kind: task.kind.rawValue,
            progress: task.fractionCompleted,
            downSpeed: task.downloadSpeed,
            upSpeed: task.uploadSpeed,
            totalBytes: task.totalBytes,
            doneBytes: task.bytesDownloaded,
            upBytes: task.bytesUploaded,
            ratio: task.shareRatio,
            seeds: task.seedCount,
            conns: task.connectionCount,
            addedAt: task.addedAt.timeIntervalSince1970,
            etaSeconds: task.estimatedTimeRemaining,
            error: RemoteRouter.errorMessage(task.status),
            source: task.source.locator,
            multiFile: task.isMultiFile,
            fileCount: task.files.count,
            streamable: RemoteStreamService.streamPlan(for: task) != nil
        )
    }
}

extension Wire.TaskDetail {
    init(_ task: DownloadTask) {
        self.init(
            row: Wire.TaskRow(task),
            savePath: task.savePath,
            sequential: task.sequentialDownload ?? false,
            infoHash: task.infoHash,
            files: task.files.map(Wire.FileRow.init),
            trackers: (task.trackers ?? []).map(Wire.TrackerRow.init),
            connections: (task.connections ?? []).map(Wire.ConnRow.init),
            pieces: task.pieceAvailability ?? [],
            server: task.remoteInfo?.server,
            mimeType: task.remoteInfo?.mimeType
        )
    }
}

extension Wire.FileRow {
    init(_ f: TransferFile) {
        self.init(
            id: f.id,
            name: f.path,
            size: f.length,
            done: f.bytesCompleted,
            progress: f.fractionCompleted,
            priority: RemoteRouter.priorityToken(f.priority)
        )
    }
}

extension Wire.TrackerRow {
    init(_ t: TorrentTracker) {
        self.init(
            url: t.url,
            host: t.host,
            tier: t.tier,
            status: t.statusLabel,
            seeds: t.seeds,
            leeches: t.leeches,
            message: t.message
        )
    }
}

extension Wire.ConnRow {
    init(_ c: TaskConnection) {
        self.init(
            id: c.id,
            label: c.label,
            detail: c.detail,
            down: c.downloadSpeed,
            up: c.uploadSpeed,
            progress: c.progress,
            adapterId: c.adapterId,
            adapterLabel: c.adapterLabel
        )
    }
}

extension Wire.HistoryRow {
    init(_ h: HistoryEntry) {
        self.init(
            id: h.id.uuidString,
            name: h.name,
            kind: h.kind.rawValue,
            totalBytes: h.totalBytes,
            savePath: h.savePath,
            completedAt: h.completedAt.timeIntervalSince1970,
            source: h.locator
        )
    }
}
