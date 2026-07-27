import Foundation

/// Reads and creates folders for the portal's save-folder picker.
///
/// **The boundary is the operating system's, not ours.** There is no configured
/// root here: a session may browse wherever the process's own uid may browse, and
/// save wherever it may write. A folder you cannot read is listed but not
/// enterable; a folder you cannot write is not offered as a destination. Both
/// answers come from `access(2)` via `FileManager`, so they are the same answers
/// the kernel would give the write itself — the picker cannot promise something
/// the filesystem will then refuse.
///
/// That is a deliberately wider reach than the downloads-root confinement this
/// replaced, and it is worth being clear about what it costs. On macOS the app
/// runs as the logged-in user, so an authenticated portal session can write into
/// any location that user can — including auto-run locations such as
/// `~/Library/LaunchAgents`. The portal's password is what stands in front of
/// that. On Linux the daemon runs as the unprivileged `goel` system user and this
/// is correspondingly narrow, which is the shape the whole design assumes.
///
/// Separate from ``DownloadManager`` so these rules can be tested against a real
/// temporary directory — with real permission bits — without a scheduler, a
/// socket, or user settings.
enum SaveFolderBrowser {

    /// One level of the tree, or nil when `path` is missing or is not a directory.
    ///
    /// `defaultFolder` is where a nil `path` opens and what the portal compares
    /// against to mean "just use the default"; `home` is the anchor for the `~/…`
    /// labels. Neither constrains anything.
    static func listing(of path: String?, defaultFolder: String, home: String) -> RemoteFolderListing? {
        let target = normalize(resolve(path, default: defaultFolder))
        let fm = FileManager.default
        guard isDirectory(target, fm) else { return nil }

        // An unreadable folder is not worth failing the request over — the picker
        // still has to show where you are and let you go back up.
        let names = (try? fm.contentsOfDirectory(atPath: target)) ?? []
        let folders = names
            // Hidden the way Finder hides them: nothing anyone means to download
            // into lives in a dot-folder, and listing them invites picking
            // `.Trash`. This is a display choice and no longer a boundary — a
            // dot-folder typed into `folder` is accepted if the uid can write it.
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

    /// Creates `name` inside `parent` and answers with its absolute path. nil when
    /// the create failed — including because the uid may not write there.
    ///
    /// `name` must already have passed ``RemoteRouter/isPlainFolderName(_:)``: that
    /// is what keeps this a single component, so the join below cannot walk
    /// anywhere the caller did not name.
    static func create(named name: String, in parent: String?, defaultFolder: String) -> String? {
        let base = normalize(resolve(parent, default: defaultFolder))
        let target = (base as NSString).appendingPathComponent(name)

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

    /// Whether `folder` can actually receive a download: it exists, it is a
    /// directory, and this uid may write to it.
    ///
    /// The same question the picker answers per row, asked once more at submit
    /// time — a folder can lose its permissions, or stop being a folder, between
    /// being picked and being used.
    static func canSave(into folder: String) -> Bool {
        let fm = FileManager.default
        let path = normalize(folder)
        return isDirectory(path, fm) && fm.isWritableFile(atPath: path)
    }

    /// The shortcut destinations the picker offers: the configured downloads
    /// folder, home, the filesystem root, and any mounted volume.
    ///
    /// Shortcuts, not boundaries — every one of them is reachable by walking Up
    /// from anywhere. They exist so the common destinations are one click away
    /// rather than eight.
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

    /// Mounted volumes, by their `/Volumes` names.
    ///
    /// Read from the directory rather than `mountedVolumeURLs`, which also returns
    /// the boot volume and the system's own data volumes — none of which are what
    /// someone means by "the external drive". Anything that resolves back to `/`
    /// is dropped for the same reason: "Computer" already covers it.
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

    /// Resolve symlinks and collapse `..` before anything looks at the result, so
    /// the path the picker shows is the path the write will use. Without this the
    /// breadcrumb could say one thing while the file landed somewhere else.
    private static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return ((expanded as NSString).resolvingSymlinksInPath as NSString).standardizingPath
    }

    private static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
