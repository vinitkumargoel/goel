import Foundation

/// Folders for the portal's save-folder picker. **The boundary is the OS's, not ours**: no configured root
/// — uid permissions (`access(2)`) decide, so on macOS the portal password guards `~/Library/LaunchAgents`.
enum SaveFolderBrowser {

    /// One level of the tree, or nil when `path` is missing/not a directory. `defaultFolder` is where a
    /// nil `path` opens, `home` anchors the `~/…` labels; neither constrains anything.
    static func listing(of path: String?, defaultFolder: String, home: String) -> RemoteFolderListing? {
        let target = normalize(resolve(path, default: defaultFolder))
        let fm = FileManager.default
        guard isDirectory(target, fm) else { return nil }

        // An unreadable folder is not worth failing the request over — the picker
        // still has to show where you are and let you go back up.
        let names = (try? fm.contentsOfDirectory(atPath: target)) ?? []
        let folders = names
            // Hidden the way Finder hides them (listing dot-folders invites picking `.Trash`).
            // Display choice, not a boundary: a typed dot-folder is accepted if the uid can write it.
            .filter { !$0.hasPrefix(".") }
            .map { (name: $0, path: (target as NSString).appendingPathComponent($0)) }
            .filter { isDirectory($0.path, fm) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                RemoteFolderListing.Entry(
                    name: $0.name, path: $0.path,
                    readable: fm.isReadableFile(atPath: $0.path),
                    writable: fm.isWritableFile(atPath: $0.path))
            }

        return RemoteFolderListing(
            path: target,
            // "/" is the only folder with nothing above it. Everywhere else the
            // picker offers Up, and permission decides whether it lands.
            parent: target == "/" ? nil : (target as NSString).deletingLastPathComponent,
            folders: folders,
            writable: fm.isWritableFile(atPath: target),
            home: normalize(home),
            defaultFolder: normalize(defaultFolder),
            places: places(defaultFolder: defaultFolder, home: home))
    }

    /// Creates `name` inside `parent`, returning its absolute path or nil (e.g. uid may not write there).
    /// `name` must have passed ``RemoteRouter/isPlainFolderName(_:)`` so the join cannot walk elsewhere.
    static func create(named name: String, in parent: String?, defaultFolder: String) -> String? {
        let base = normalize(resolve(parent, default: defaultFolder))
        let target = (base as NSString).appendingPathComponent(name)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target, isDirectory: &isDir) {
            // Already there: succeed if it is a folder — failing would only push the user to
            // invent a second name for a folder they already have.
            return isDir.boolValue ? target : nil
        }
        do {
            // No intermediates: `name` is a single validated component, so allowing them would
            // quietly accept a name with a separator if that validation ever loosened.
            try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
            return target
        } catch {
            GoelLog.remote.error("Remote folder create failed", .detail(error.localizedDescription))
            return nil
        }
    }

    /// Whether `folder` can receive a download: exists, is a directory, and this uid may write it.
    /// Re-asked at submit time because permissions (or the folder itself) can change after picking.
    static func canSave(into folder: String) -> Bool {
        let fm = FileManager.default
        let path = normalize(folder)
        return isDirectory(path, fm) && fm.isWritableFile(atPath: path)
    }

    /// Shortcut destinations: downloads folder, home, filesystem root, mounted volumes. Shortcuts,
    /// not boundaries — all are reachable by walking Up anyway; this just saves clicks.
    static func places(defaultFolder: String, home: String) -> [RemoteFolderListing.Entry] {
        let fm = FileManager.default
        var out: [RemoteFolderListing.Entry] = []
        var seen = Set<String>()

        func add(_ name: String, _ path: String) {
            let full = normalize(path)
            guard !seen.contains(full), isDirectory(full, fm) else { return }
            seen.insert(full)
            out.append(RemoteFolderListing.Entry(
                name: name, path: full,
                readable: fm.isReadableFile(atPath: full),
                writable: fm.isWritableFile(atPath: full)))
        }

        add("Downloads", defaultFolder)
        add("Home", home)
        for volume in mountedVolumes() { add(volume.name, volume.path) }
        add("Computer", "/")
        return out
    }

    /// Mounted volumes by their `/Volumes` names. Read from the directory, not `mountedVolumeURLs`,
    /// which also returns boot/system data volumes; anything resolving to `/` is dropped ("Computer").
    private static func mountedVolumes() -> [(name: String, path: String)] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .map { (name: $0, path: "/Volumes/" + $0) }
            .filter { normalize($0.path) != "/" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func resolve(_ path: String?, default fallback: String) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Resolve symlinks and collapse `..` first, so the path the picker shows is the path the write
    /// uses — otherwise the breadcrumb could say one thing while the file landed somewhere else.
    private static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return ((expanded as NSString).resolvingSymlinksInPath as NSString).standardizingPath
    }

    private static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
