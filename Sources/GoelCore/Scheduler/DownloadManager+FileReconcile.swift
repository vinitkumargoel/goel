import Foundation

extension DownloadManager {

    static let fileReconcileInterval: UInt64 = 5

    private struct PayloadProbe: Sendable {
        let id: DownloadTask.ID
        let saveDirectory: String
        let savePath: String
    }

    /// `unknown` covers every "can't tell": an unmounted volume, EACCES/EPERM from a TCC-protected
    /// folder, an SMB hiccup. Only a definite ENOENT counts as missing.
    enum PayloadState: Sendable, Equatable { case present, missing, unknown }

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

    /// Flags completed rows whose payload is gone and clears the flag when it comes back. Never drops a
    /// row: the user moving a finished file in Finder must not erase its record with no word.
    /// `stat` stays off the actor: one unresponsive SMB/NFS share would stall every engine event.
    public func reconcileCompletedFiles() async {
        let probes = tasks.compactMap { task -> PayloadProbe? in
            guard task.status == .completed else { return nil }
            return PayloadProbe(id: task.id,
                                saveDirectory: task.saveDirectory,
                                savePath: task.savePath)
        }
        guard !probes.isEmpty else { return }

        let verdicts = await Task.detached(priority: .utility) {
            probes.map { ($0, Self.payloadState(saveDirectory: $0.saveDirectory, savePath: $0.savePath)) }
        }.value

        if applyPayloadVerdicts(verdicts) { publish() }
    }

    /// Recheck each row: the probe is a stale snapshot and must not overrule newer state.
    private func applyPayloadVerdicts(_ verdicts: [(PayloadProbe, PayloadState)]) -> Bool {
        var changed = false
        var newlyMissing: [String] = []
        for (probe, state) in verdicts {
            guard let i = index(of: probe.id),
                  tasks[i].status == .completed, tasks[i].savePath == probe.savePath else { continue }
            switch state {
            case .missing where tasks[i].fileMissing != true:
                tasks[i].fileMissing = true
                newlyMissing.append(tasks[i].name)
            case .present where tasks[i].fileMissing == true:
                tasks[i].fileMissing = nil
            default:
                continue
            }
            persist(tasks[i])
            changed = true
        }
        if newlyMissing.count == 1, let name = newlyMissing.first {
            postNotice(L10n.t("Can’t find the file for “%@” — it may have been moved or deleted. It stays in your list.", name),
                       isError: false)
        } else if newlyMissing.count > 1 {
            postNotice(L10n.t("Can’t find the files for %d completed downloads — they may have been moved or deleted. They stay in your list.",
                              newlyMissing.count),
                       isError: false)
        }
        return changed
    }

    static func completedPayloadIsMissing(_ task: DownloadTask, fileManager fm: FileManager) -> Bool {
        payloadIsMissing(saveDirectory: task.saveDirectory, savePath: task.savePath, fileManager: fm)
    }

    /// An absent containing directory means "unknown" (unmounted volume), never "deleted".
    static func payloadIsMissing(saveDirectory: String, savePath: String, fileManager fm: FileManager) -> Bool {
        payloadState(saveDirectory: saveDirectory, savePath: savePath) == .missing
    }

    /// `fileExists` can't tell ENOENT from EACCES, so this asks `stat` and reads `errno`.
    static func payloadState(saveDirectory: String, savePath: String) -> PayloadState {
        var info = stat()
        guard stat(saveDirectory, &info) == 0 else { return .unknown }
        if stat(savePath, &info) == 0 { return .present }
        return errno == ENOENT ? .missing : .unknown
    }

    func dropTaskLocally(_ id: DownloadTask.ID) {
        clearLocalState(id, removeFromList: true)
        persistRemoval(id)
    }
}
