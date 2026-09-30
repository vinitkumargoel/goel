import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// In-progress HTTP bytes live beside the destination, never under its name: a full-size sparse file
/// there reads as complete to Spotlight and backups, and "overwrite" would destroy the good copy up front.
public enum PartialFile {
    public static let suffix = ".goelpart"

    public static func path(for savePath: String) -> String { savePath + suffix }

    static func url(for destination: URL) -> URL {
        URL(fileURLWithPath: path(for: destination.path))
    }
}

extension HTTPEngine {

    /// Builds before `.goelpart` wrote the partial under the final name; a resume must pick it up, not restart.
    static func adoptLegacyPartial(final: URL, part: URL, hasResume: Bool) {
        let fm = FileManager.default
        guard hasResume, !fm.fileExists(atPath: part.path), fm.fileExists(atPath: final.path) else { return }
        do {
            try fm.moveItem(at: final, to: part)
        } catch {
            GoelLog.engineHTTP.notice("Couldn't adopt legacy partial; resume will restart",
                                      .detail(error.localizedDescription), .path(final.path))
        }
    }

    /// Returns where the file landed. "overwrite" replaces atomically (rename(2): readers see the old file
    /// or the finished one). Otherwise a file that appeared at the final path mid-transfer is never
    /// clobbered: the move is exclusive, and a conflict steps to the next free `name (n)`.
    static func finalizePartial(_ part: URL, to final: URL, overwrite: Bool = true) throws -> URL {
        if overwrite {
            guard rename(part.path, final.path) == 0 else { throw finalizeFailure(errno) }
            return final
        }
        let directory = final.deletingLastPathComponent().path
        var target = final
        for _ in 0..<16 {
            let code = moveExclusive(part.path, to: target.path)
            if code == 0 { return target }
            guard code == EEXIST else { throw finalizeFailure(code) }
            // Lost a race to another writer: take the next free name. `uniqueName` also skips `.goelpart`s.
            target = URL(fileURLWithPath: directory)
                .appendingPathComponent(PathSafety.uniqueName(base: final.lastPathComponent, in: directory))
        }
        throw finalizeFailure(EEXIST)
    }

    private static func finalizeFailure(_ code: Int32) -> DownloadError {
        .unknown("Couldn't move the finished download into place: \(String(cString: strerror(code)))")
    }

    /// 0 or an errno. EEXIST = something already sits at `to`; the partial is left untouched.
    static func moveExclusive(_ from: String, to: String) -> Int32 {
        #if canImport(Darwin)
        return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        #else
        // link(2) fails atomically on an existing target; a filesystem without hard links gets check+rename.
        if link(from, to) == 0 {
            unlink(from)
            return 0
        }
        let code = errno
        guard code == EPERM || code == ENOTSUP || code == EXDEV else { return code }
        if FileManager.default.fileExists(atPath: to) { return EEXIST }
        return rename(from, to) == 0 ? 0 : errno
        #endif
    }

    /// Two live tasks must never share one `.goelpart`. Completed rows don't count — they own no partial,
    /// and counting them made "overwrite" rename to `name (1)` — but failed ones do: a retry resumes from
    /// theirs. Under "rename" a file already at the final path is stepped over too; candidates skip any
    /// name with a file or partial on disk.
    func nameAvoidingActivePartials(_ name: String, for id: UUID, in directory: String) -> String {
        let taken = Set(tasks.values.filter {
            $0.id != id && $0.saveDirectory == directory && $0.status != .completed
        }.map(\.name))
        let fm = FileManager.default
        let renames = fileConflictPolicy != "overwrite"
        let baseOnDisk = renames && fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name))
        guard taken.contains(name) || baseOnDisk else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        for n in 1...9_999 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let path = (directory as NSString).appendingPathComponent(candidate)
            if !taken.contains(candidate), !fm.fileExists(atPath: path),
               !fm.fileExists(atPath: PartialFile.path(for: path)) { return candidate }
        }
        return name
    }

    /// The partial is scratch and goes outright; a finished file goes to the Trash so a stray confirm is undoable.
    /// The final path is only ours once complete — before that it may be a file "overwrite" hasn't replaced yet.
    static func removeDownloadedData(hub: EventHub, id: UUID, task: DownloadTask) {
        let fm = FileManager.default
        let partPath = PartialFile.path(for: task.savePath)
        let hadPartial = fm.fileExists(atPath: partPath)
        try? fm.removeItem(atPath: partPath)
        let legacyPartial = task.resumeData != nil && !hadPartial
        guard task.status == .completed || legacyPartial else { return }
        do {
            try trashOrRemove(URL(fileURLWithPath: task.savePath))
        } catch {
            guard fm.fileExists(atPath: task.savePath) else { return }
            hub.fail(id, DownloadError.unknown(
                "Removed “\(task.name)” from the list, but its file is still on disk: \(error.localizedDescription)"))
        }
    }

    static func trashOrRemove(_ url: URL) throws {
        try RemoteTransferPrep.trashOrDelete(url)   // one seam, so tests never touch ~/.Trash
    }
}
