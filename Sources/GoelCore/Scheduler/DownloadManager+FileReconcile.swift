import Foundation

extension DownloadManager {

    static let fileReconcileInterval: UInt64 = 5

    private struct PayloadProbe: Sendable {
        let id: DownloadTask.ID
        let saveDirectory: String
        let savePath: String
    }

    func startFileReconcile() {
        fileReconcileTask?.cancel()
        fileReconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.fileReconcileInterval * 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.reconcileCompletedFiles()
            }
        }
    }

    /// `stat` must stay off the actor: one unresponsive SMB/NFS share would stall every engine event.
    public func reconcileCompletedFiles() async {
        let probes = tasks.compactMap { task -> PayloadProbe? in
            guard task.status == .completed else { return nil }
            return PayloadProbe(id: task.id,
                                saveDirectory: task.saveDirectory,
                                savePath: task.savePath)
        }
        guard !probes.isEmpty else { return }

        // A private `FileManager`, not `.default`: no instance state shared with other threads.
        let missing = await Task.detached(priority: .utility) {
            let fm = FileManager()
            return probes.filter {
                Self.payloadIsMissing(saveDirectory: $0.saveDirectory, savePath: $0.savePath, fileManager: fm)
            }
        }.value

        guard pruneConfirmedMissing(missing) else { return }
        publish()
        schedule()
    }

    /// Recheck each row: the probe is a stale snapshot and must not overrule newer state.
    private func pruneConfirmedMissing(_ probes: [PayloadProbe]) -> Bool {
        var pruned = false
        for probe in probes {
            guard let i = index(of: probe.id) else { continue }
            let task = tasks[i]
            guard task.status == .completed, task.savePath == probe.savePath else { continue }
            dropTaskLocally(probe.id)
            pruned = true
        }
        return pruned
    }

    /// Blocking — only safe from `restore()` at launch; the periodic sweep uses the async variant.
    @discardableResult
    func pruneMissingCompletedFiles() -> Bool {
        let fm = FileManager.default
        let gone = tasks.filter {
            $0.status == .completed && Self.completedPayloadIsMissing($0, fileManager: fm)
        }
        guard !gone.isEmpty else { return false }
        for task in gone { dropTaskLocally(task.id) }
        return true
    }

    static func completedPayloadIsMissing(_ task: DownloadTask, fileManager fm: FileManager) -> Bool {
        payloadIsMissing(saveDirectory: task.saveDirectory, savePath: task.savePath, fileManager: fm)
    }

    /// An absent containing directory means "unknown" (unmounted volume), never "deleted".
    static func payloadIsMissing(saveDirectory: String, savePath: String, fileManager fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: saveDirectory) else { return false }
        return !fm.fileExists(atPath: savePath)
    }

    func dropTaskLocally(_ id: DownloadTask.ID) {
        clearLocalState(id, removeFromList: true)
        persistRemoval(id)
    }
}
