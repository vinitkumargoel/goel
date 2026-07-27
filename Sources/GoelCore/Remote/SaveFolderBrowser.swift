import Foundation

/// Reads and creates folders under the downloads root for the portal's save-folder
/// picker.
///
/// Separate from ``DownloadManager`` so the containment rules can be tested against
/// a real temporary directory without a scheduler, a socket, or user settings —
/// these are the checks that decide whether a remote caller can reach the rest of
/// the filesystem, so they deserve tests that are cheap to write.
///
/// Every entry point takes `root` explicitly and re-derives containment from it.
/// Nothing here caches a resolved root: the setting can change under a long-lived
/// daemon, and a stale root would be a stale boundary.
enum SaveFolderBrowser {

    /// One level of the tree, or nil when `path` is outside `root`, missing, or
    /// not a directory.
    static func listing(of path: String?, root: String) -> RemoteFolderListing? {
        let target = resolve(path, default: root)
        guard PathSafety.isContained(target, within: root) else {
            GoelLog.remote.error("Remote folders: refusing a path outside the downloads folder")
            return nil
        }
        let fm = FileManager.default
        guard isDirectory(target, fm) else { return nil }

        // An unreadable folder is not worth failing the request over — the picker
        // still has to show where you are and let you go back up.
        let names = (try? fm.contentsOfDirectory(atPath: target)) ?? []
        let folders = names
            // Hidden for the same reason `isPlainFolderName` refuses to create
            // them: nothing anyone means to download into lives in a dot-folder,
            // and listing them invites picking `.Trash`.
            .filter { !$0.hasPrefix(".") }
            .map { (name: $0, path: (target as NSString).appendingPathComponent($0)) }
            .filter { isDirectory($0.path, fm) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { RemoteFolderListing.Entry(name: $0.name, path: $0.path) }

        // Comparing through `isContained` rather than string equality, because
        // `root` may carry a trailing slash or a symlinked prefix that `target`
        // does not — only one of the two can contain the other at the top.
        let atRoot = PathSafety.isContained(root, within: target)

        return RemoteFolderListing(
            root: root,
            path: target,
            parent: atRoot ? nil : (target as NSString).deletingLastPathComponent,
            folders: folders,
            writable: fm.isWritableFile(atPath: target))
    }

    /// Creates `name` inside `parent` and answers with its absolute path. nil when
    /// the result would sit outside `root` or the create failed.
    ///
    /// `name` must already have passed ``RemoteRouter/isPlainFolderName(_:)``; the
    /// containment checks here are the backstop, not the validation.
    static func create(named name: String, in parent: String?, root: String) -> String? {
        let base = resolve(parent, default: root)
        // Checked before the join, so a hostile `parent` never reaches `mkdir`…
        guard PathSafety.isContained(base, within: root) else {
            GoelLog.remote.error("Remote folder create: refusing a parent outside the downloads folder")
            return nil
        }
        let target = (base as NSString).appendingPathComponent(name)
        // …and again after it, because `base` may be a symlink whose target is
        // inside the root while a child of it resolves back out.
        guard PathSafety.isContained(target, within: root) else {
            GoelLog.remote.error("Remote folder create: refusing a path outside the downloads folder")
            return nil
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target, isDirectory: &isDir) {
            // Already there: succeed if it is a folder. Asking for a folder you
            // already have is satisfied by the folder you already have; failing
            // would only push the user to invent a second name for it.
            return isDir.boolValue ? target : nil
        }
        do {
            // No intermediates: `name` is a single validated component, so there
            // are none to create, and allowing them would quietly accept a name
            // with a separator in it if that validation ever loosened.
            try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
            return target
        } catch {
            GoelLog.remote.error("Remote folder create failed", .detail(error.localizedDescription))
            return nil
        }
    }

    private static func resolve(_ path: String?, default fallback: String) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
