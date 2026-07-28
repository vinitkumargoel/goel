import Foundation

/// **The boundary is the OS's, not ours**: there is no configured root — uid permissions decide, so the portal password is the guard.
enum SaveFolderBrowser {

    static func listing(of path: String?, defaultFolder: String, home: String) -> RemoteFolderListing? {
        let target = normalize(resolve(path, default: defaultFolder))
        let fm = FileManager.default
        guard isDirectory(target, fm) else { return nil }

        let names = (try? fm.contentsOfDirectory(atPath: target)) ?? []
        let folders = names
            // A display choice, not a boundary: a typed dot-folder is still accepted if the uid can write it.
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
            parent: target == "/" ? nil : (target as NSString).deletingLastPathComponent,
            folders: folders,
            writable: fm.isWritableFile(atPath: target),
            home: normalize(home),
            defaultFolder: normalize(defaultFolder),
            places: places(defaultFolder: defaultFolder, home: home))
    }

    /// `name` must have passed ``RemoteRouter/isPlainFolderName(_:)`` so the join cannot walk elsewhere.
    static func create(named name: String, in parent: String?, defaultFolder: String) -> String? {
        let base = normalize(resolve(parent, default: defaultFolder))
        let target = (base as NSString).appendingPathComponent(name)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target, isDirectory: &isDir) {
            return isDir.boolValue ? target : nil
        }
        do {
            // No intermediates: allowing them would quietly accept a name with a separator if validation loosened.
            try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
            return target
        } catch {
            GoelLog.remote.error("Remote folder create failed", .detail(error.localizedDescription))
            return nil
        }
    }

    /// Re-asked at submit time because permissions (or the folder itself) can change after picking.
    static func canSave(into folder: String) -> Bool {
        let fm = FileManager.default
        let path = normalize(folder)
        return isDirectory(path, fm) && fm.isWritableFile(atPath: path)
    }

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

    /// Resolve symlinks and collapse `..` first, or the path shown is not the path written to.
    private static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return ((expanded as NSString).resolvingSymlinksInPath as NSString).standardizingPath
    }

    private static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
