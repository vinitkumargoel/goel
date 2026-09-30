import Foundation

/// No configured root — uid permissions decide — except that a remote caller may never pick a
/// system, hidden or `~/Library` folder (see ``isProtected(_:home:defaultFolder:)``): a token holder
/// saving `x.plist` into `~/Library/LaunchAgents` would run code at the next login.
enum SaveFolderBrowser {

    static func listing(of path: String?, defaultFolder: String, home: String) -> RemoteFolderListing? {
        let target = normalize(resolve(path, default: defaultFolder))
        let fm = FileManager.default
        guard isDirectory(target, fm) else { return nil }
        // `/` stays browsable (it is how you reach /Volumes and /mnt); its protected children are hidden below.
        guard target == "/" || !isProtected(target, home: home, defaultFolder: defaultFolder) else {
            return nil
        }

        let names = (try? fm.contentsOfDirectory(atPath: target)) ?? []
        let folders = names
            // A display choice, not a boundary: a typed dot-folder is still accepted if the uid can write it.
            .filter { !$0.hasPrefix(".") }
            .map { (name: $0, path: (target as NSString).appendingPathComponent($0)) }
            .filter { isDirectory($0.path, fm) }
            .filter { !isProtected($0.path, home: home, defaultFolder: defaultFolder) }
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
            writable: fm.isWritableFile(atPath: target)
                && !isProtected(target, home: home, defaultFolder: defaultFolder),
            home: normalize(home),
            defaultFolder: normalize(defaultFolder),
            places: places(defaultFolder: defaultFolder, home: home))
    }

    /// `name` must have passed ``RemoteRouter/isPlainFolderName(_:)`` so the join cannot walk elsewhere.
    static func create(named name: String, in parent: String?, defaultFolder: String,
                       home: String = NSHomeDirectory()) -> String? {
        let base = normalize(resolve(parent, default: defaultFolder))
        let target = (base as NSString).appendingPathComponent(name)
        guard !isProtected(target, home: home, defaultFolder: defaultFolder) else {
            GoelLog.remote.error("Remote folder create refused: protected location", .path(base))
            return nil
        }

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
    static func canSave(into folder: String, defaultFolder: String? = nil,
                        home: String = NSHomeDirectory()) -> Bool {
        let fm = FileManager.default
        let path = normalize(folder)
        return isDirectory(path, fm) && fm.isWritableFile(atPath: path)
            && !isProtected(path, home: home, defaultFolder: defaultFolder)
    }

    /// Both spellings: `resolvingSymlinksInPath` drops a leading `/private` only for paths that exist.
    static let protectedRoots: [String] = [
        "/etc", "/private/etc", "/usr", "/bin", "/sbin", "/System", "/Library",
        "/var", "/private/var", "/opt", "/Applications", "/dev", "/cores",
        // Linux
        "/boot", "/proc", "/sys", "/root", "/run", "/lib", "/lib64",
    ]

    /// Checked on the symlink-resolved, `..`-collapsed path, so a link cannot launder a destination.
    /// Temp dirs, home (minus hidden folders and `~/Library`) and the operator's default folder stay
    /// usable even when they sit under a protected root (`/var/folders/…/T`, a daemon home in /var/lib).
    static func isProtected(_ path: String, home: String, defaultFolder: String? = nil) -> Bool {
        let target = normalize(path)
        if target == "/" { return true }
        let homeDir = normalize(home)
        let defaultDir = defaultFolder.map(normalize).flatMap { $0 == "/" ? nil : $0 }
        func within(_ root: String) -> Bool { target == root || target.hasPrefix(root + "/") }

        // Dot folders (`.ssh`, `.config/autostart`, `.zshrc.d`) are shell and login hooks.
        // The default folder's own spelling is the operator's choice, so only what lies below it counts.
        let judged = defaultDir.flatMap { within($0) ? String(target.dropFirst($0.count)) : nil } ?? target
        if judged.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return true }

        if within(normalize(homeDir + "/Library")) || within(homeDir + "/Library") { return true }
        let temps = ["/tmp", "/private/tmp", normalize(NSTemporaryDirectory()), NSTemporaryDirectory()]
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        if temps.contains(where: within) { return false }
        if let defaultDir, within(defaultDir) { return false }
        if homeDir != "/", within(homeDir) { return false }
        return protectedRoots.contains(where: within)
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
