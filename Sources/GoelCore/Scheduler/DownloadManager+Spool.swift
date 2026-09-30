import Foundation

/// Keeps the spooled .torrent of every row removed under it on disk for as long as the caller can still
/// undo the removal. The app ties one to each Undo record; when the record goes, so does the hold, and
/// any file no row, history entry or other hold still names is deleted.
public final class RemovalHold: Sendable {
    let manager: DownloadManager
    let token = UUID()

    public init(manager: DownloadManager) { self.manager = manager }

    deinit {
        let manager = self.manager, token = self.token
        Task { await manager.releaseRemovalHold(token) }
    }
}

extension DownloadManager {

    /// A spool file younger than this is left by the launch sweep: an upload may have written it and not
    /// yet added its row.
    static let spoolSweepGrace: TimeInterval = 10 * 60

    func holdSpool(_ source: DownloadSource, under hold: RemovalHold) {
        guard let directory = spoolDirectory, RemoteTorrentSpool.isSpooled(source, in: directory) else { return }
        spoolHolds[hold.token, default: []].append(source)
    }

    func releaseRemovalHold(_ token: UUID) async {
        guard let sources = spoolHolds.removeValue(forKey: token) else { return }
        await discardOrphanedSpools(sources)
    }

    /// Deletes those of `sources` that are spooled uploads nothing refers to any more: not a listed row,
    /// not an Undo hold, not a history entry (whose Download Again re-adds from the file).
    func discardOrphanedSpools(_ sources: [DownloadSource], ignoringHistory ignored: Set<UUID> = [],
                               ignoringAllHistory: Bool = false) async {
        guard let directory = spoolDirectory else { return }
        let candidates = sources.filter { RemoteTorrentSpool.isSpooled($0, in: directory) }
        guard !candidates.isEmpty,
              let referenced = spoolReferences(ignoringHistory: ignored, ignoringAllHistory: ignoringAllHistory)
        else { return }
        let orphans = candidates.filter { source in
            RemoteTorrentSpool.spoolName(source, in: directory).map { !referenced.contains($0) } ?? false
        }
        guard !orphans.isEmpty else { return }
        // Off the actor: a slow disk must not stall every download's bookkeeping.
        await Task.detached(priority: .utility) {
            for source in orphans { RemoteTorrentSpool.discard(source, directory: directory) }
        }.value
    }

    /// Spool file names still in use. nil when history couldn't be read: deleting then might break
    /// Download Again.
    private func spoolReferences(ignoringHistory ignored: Set<UUID>, ignoringAllHistory: Bool) -> Set<String>? {
        guard let directory = spoolDirectory else { return nil }
        var sources = tasks.map(\.source)
        for held in spoolHolds.values { sources += held }
        if !ignoringAllHistory, let store {
            do {
                for entry in try store.loadHistory(limit: Int(Int32.max)) where !ignored.contains(entry.id) {
                    if let url = URL(string: entry.locator), url.isFileURL { sources.append(.torrentFile(url)) }
                }
            } catch {
                GoelLog.persistence.error("History load failed; spooled torrents kept",
                                          .detail(String(describing: error)))
                return nil
            }
        }
        return Set(sources.compactMap { RemoteTorrentSpool.spoolName($0, in: directory) })
    }

    func historySources(_ ids: Set<UUID>?) -> [DownloadSource] {
        guard let store, let entries = try? store.loadHistory(limit: Int(Int32.max)) else { return [] }
        return entries.filter { ids?.contains($0.id) ?? true }.compactMap { entry in
            guard let url = URL(string: entry.locator), url.isFileURL else { return nil }
            return .torrentFile(url)
        }
    }

    /// Launch sweep: a hold never outlives the process, so a spool file no row or history entry names is
    /// one an earlier session removed (or crashed before cleaning up). The app calls it only with its real,
    /// on-disk queue: judged against a temporary database, every upload would look orphaned.
    public func sweepOrphanedSpool(now: Date = Date()) async {
        guard restoredQueue, let directory = spoolDirectory,
              let referenced = spoolReferences(ignoringHistory: [], ignoringAllHistory: false) else { return }
        let grace = Self.spoolSweepGrace
        await Task.detached(priority: .utility) {
            let fm = FileManager()
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))
                ?? []
            for file in files where file.pathExtension == "torrent" {
                // Rebuilt on `directory` so a resolved `/private/var` spelling still passes `discard`'s check.
                let source = DownloadSource.torrentFile(directory.appendingPathComponent(file.lastPathComponent))
                guard !referenced.contains(file.lastPathComponent) else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                guard now.timeIntervalSince(modified) > grace else { continue }
                RemoteTorrentSpool.discard(source, directory: directory)
            }
        }.value
    }

    /// Tests point the spool at a temporary directory.
    func setSpoolDirectory(_ directory: URL?) { spoolDirectory = directory }
}
