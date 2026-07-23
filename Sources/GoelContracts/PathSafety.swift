import Foundation

/// Filesystem-safety primitives: reduce hostile names to a single safe component,
/// clamp names to a filesystem-legal byte length, allocate never-clobber unique
/// names, and verify a path stays inside an allowed directory.
///
/// These are the app's most-reused and most security-critical string operations
/// (~20 call sites across every engine, the scheduler, persistence, the remote
/// router, and the macOS app). They are pure and instance-independent, so they
/// live in a dedicated namespace with a small named interface rather than hiding
/// as statics on the ``DownloadTask`` data model. The containment/sanitisation
/// invariants get one auditable home reused everywhere.
public enum PathSafety {

    /// Reduce a raw, possibly hostile name down to a single safe filename
    /// component. Strips any directory parts (defeating `../` traversal and
    /// absolute paths) and rejects empty, `.`/`..`, hidden, and slash-bearing
    /// names, falling back to `fallback`.
    public static func sanitizedName(_ raw: String, fallback: String = "download") -> String {
        let last = (raw as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty || last == "." || last == ".." || last.hasPrefix(".") || last.contains("/") {
            return fallback
        }
        return clampLength(last)
    }

    /// Clamp a filename to a filesystem-safe byte length. macOS's `NAME_MAX` is
    /// 255 UTF-8 bytes; a longer name fails the write outright
    /// (`NSFileWriteInvalidFileNameError` — "the file name … is invalid"), which
    /// is exactly what opaque, query-token CDN URLs (Google video-downloads,
    /// signed S3 links, …) produce when their last path component is hundreds of
    /// characters long. We clamp well under the hard limit to leave room for a
    /// conflict suffix like ` (12)`, and we preserve the extension so the file
    /// stays openable.
    public static func clampLength(_ name: String, maxBytes: Int = 240) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        // Reserve room for ".<ext>"; if the extension itself is absurdly long
        // (not a real extension), drop it and just clamp the whole string.
        let extBudget = (!ext.isEmpty && ext.utf8.count <= 16) ? ext.utf8.count + 1 : 0
        let stemBudget = max(1, maxBytes - extBudget)
        let clampedStem = truncateUTF8(stem, toBytes: stemBudget)
        return extBudget == 0 ? truncateUTF8(name, toBytes: maxBytes)
                              : clampedStem + "." + ext
    }

    /// Truncate a string to at most `max` UTF-8 bytes without splitting a
    /// multi-byte character.
    private static func truncateUTF8(_ s: String, toBytes max: Int) -> String {
        guard s.utf8.count > max else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > max { break }
            out.append(ch)
            used += n
        }
        return out.isEmpty ? String(s.prefix(1)) : out
    }

    /// Return `base` if no file with that name exists in `directory`, otherwise
    /// append ` (1)`, ` (2)`, … before the extension until the path is free
    /// (never-clobber). Bounded so a pathological directory can't spin forever.
    public static func uniqueName(base: String, in directory: String) -> String {
        let fm = FileManager.default
        let path = (directory as NSString).appendingPathComponent(base)
        guard fm.fileExists(atPath: path) else { return base }
        let ns = base as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        for n in 1...9_999 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidatePath = (directory as NSString).appendingPathComponent(candidate)
            if !fm.fileExists(atPath: candidatePath) { return candidate }
        }
        return base
    }

    /// Whether `path` resolves to a location at or strictly inside `directory`.
    /// Resolves symlinks *and* collapses `.`/`..` on both sides so neither a
    /// symlinked directory/component nor a `../` element can let the resolved path
    /// escape the resolved root (`resolvingSymlinksInPath` handles symlinks but
    /// leaves `..`; `standardizingPath` collapses `..` — applying both is robust).
    /// Used to guard save paths, to constrain a remote-supplied save directory to
    /// an allowed downloads root, and to verify engine-declared file paths
    /// (torrent/HLS) stay within the save directory.
    public static func isContained(_ path: String, within directory: String) -> Bool {
        func normalize(_ p: String) -> String {
            ((p as NSString).resolvingSymlinksInPath as NSString).standardizingPath
        }
        let dir = normalize(directory)
        let full = normalize(path)
        return full == dir || full.hasPrefix(dir + "/")
    }
}
