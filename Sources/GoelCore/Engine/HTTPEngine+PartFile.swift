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

    /// rename(2) replaces atomically: readers see the old file or the finished one, never a torn write.
    static func finalizePartial(_ part: URL, to final: URL) throws {
        guard rename(part.path, final.path) == 0 else {
            let code = errno
            throw DownloadError.unknown(
                "Couldn't move the finished download into place: \(String(cString: strerror(code)))")
        }
    }

    /// Two live tasks must never share one `.goelpart`; the final name no longer occupies the disk to prevent it.
    func nameAvoidingActivePartials(_ name: String, for id: UUID, in directory: String) -> String {
        let taken = Set(tasks.values.filter { $0.id != id && $0.saveDirectory == directory }.map(\.name))
        guard taken.contains(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let fm = FileManager.default
        for n in 1...9_999 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let path = (directory as NSString).appendingPathComponent(candidate)
            if !taken.contains(candidate), !fm.fileExists(atPath: path) { return candidate }
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
        let fm = FileManager.default
        #if os(macOS)
        do {
            try RemoteTransferPrep.trashItem(url)   // one seam, so tests never touch ~/.Trash
            return
        } catch {
            // Volumes without a Trash (network shares, some externals) still have to honour "delete".
            guard fm.fileExists(atPath: url.path) else { return }
        }
        #endif
        try fm.removeItem(at: url)
    }
}
