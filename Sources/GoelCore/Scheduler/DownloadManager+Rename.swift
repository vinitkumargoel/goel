import Foundation

extension DownloadManager {

    public enum RenameResult: Sendable, Equatable {
        case renamed(String)
        case unchanged
        case notFound
        case unsupported
        case active
        case ioError(String)
    }

    @discardableResult
    public func rename(_ id: DownloadTask.ID, to newName: String) async -> RenameResult {
        guard let i = index(of: id) else { return .notFound }
        let task = tasks[i]
        guard task.kind != .torrent else { return .unsupported }
        guard !task.status.isActive else { return .active }
        let sanitized = PathSafety.sanitizedName(newName, fallback: task.name)
        guard sanitized != task.name else { return .unchanged }
        let fm = FileManager.default
        let dir = task.saveDirectory
        let finalName = PathSafety.uniqueName(base: sanitized, in: dir)
        let newPath = (dir as NSString).appendingPathComponent(finalName)
        let newPart = PartialFile.path(for: newPath)
        // A stale partial at the new name would be resumed as if it were this download's bytes.
        if task.status != .completed, fm.fileExists(atPath: newPart) {
            return .ioError(L10n.t("“%@” already exists in that folder.", (newPart as NSString).lastPathComponent))
        }
        let moves = Self.renameMoves(for: task, to: newPath) { fm.fileExists(atPath: $0) }
        if let error = Self.perform(moves, fileManager: fm) { return .ioError(error) }
        tasks[i].name = finalName
        persist(tasks[i])
        publish()
        await refreshEngineCopy(id)
        return .renamed(finalName)
    }

    struct RenameMove: Equatable {
        var from: String
        var to: String
    }

    /// Partial first. An unfinished HTTP download's bytes are in `.goelpart`: its `savePath` may be the user's
    /// own file (overwrite policy), so it only moves when it is a pre-`.goelpart` partial. FTP/SFTP/HLS write
    /// `savePath` itself, and a finished download of any kind is `savePath`.
    static func renameMoves(for task: DownloadTask, to newPath: String,
                            fileExists: (String) -> Bool) -> [RenameMove] {
        let oldPath = task.savePath
        let oldPart = PartialFile.path(for: oldPath), newPart = PartialFile.path(for: newPath)
        var moves: [RenameMove] = []
        if fileExists(oldPart) { moves.append(RenameMove(from: oldPart, to: newPart)) }
        let ownsFinal: Bool
        if task.kind == .http, task.status != .completed {
            ownsFinal = task.resumeData != nil && !fileExists(oldPart)
        } else {
            ownsFinal = true
        }
        if ownsFinal, fileExists(oldPath) { moves.append(RenameMove(from: oldPath, to: newPath)) }
        return moves
    }

    /// All or nothing: a half-done rename leaves the name and the bytes disagreeing, so earlier moves roll back.
    /// Returns the error to show, or nil on success.
    static func perform(_ moves: [RenameMove], fileManager fm: FileManager) -> String? {
        var done: [RenameMove] = []
        func rollBack() {
            for move in done.reversed() { try? fm.moveItem(atPath: move.to, toPath: move.from) }
        }
        for move in moves {
            if fm.fileExists(atPath: move.to) {
                rollBack()
                return L10n.t("“%@” already exists in that folder.", (move.to as NSString).lastPathComponent)
            }
            do {
                try fm.moveItem(atPath: move.from, toPath: move.to)
                done.append(move)
            } catch {
                rollBack()
                return error.localizedDescription
            }
        }
        return nil
    }
}
