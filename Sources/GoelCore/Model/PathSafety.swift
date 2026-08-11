import Foundation

public enum PathSafety {

    /// Strips directory parts to defeat `../` traversal and absolute paths in a hostile name.
    public static func sanitizedName(_ raw: String, fallback: String = "download") -> String {
        let last = (raw as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty || last == "." || last == ".." || last.hasPrefix(".") || last.contains("/") {
            return fallback
        }
        return clampLength(last)
    }

    /// macOS `NAME_MAX` is 255 UTF-8 bytes; 240 leaves room for a ` (12)` suffix.
    public static func clampLength(_ name: String, maxBytes: Int = 240) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let extBudget = (!ext.isEmpty && ext.utf8.count <= 16) ? ext.utf8.count + 1 : 0
        let stemBudget = max(1, maxBytes - extBudget)
        let clampedStem = truncateUTF8(stem, toBytes: stemBudget)
        return extBudget == 0 ? truncateUTF8(name, toBytes: maxBytes)
                              : clampedStem + "." + ext
    }

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

    /// Never clobbers an existing file; the loop is bounded so a pathological directory can't spin.
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

    /// Must resolve symlinks *and* collapse `..` on both sides — either alone leaves an escape.
    public static func isContained(_ path: String, within directory: String) -> Bool {
        func normalize(_ p: String) -> String {
            ((p as NSString).resolvingSymlinksInPath as NSString).standardizingPath
        }
        let dir = normalize(directory)
        let full = normalize(path)
        if full == dir || full.hasPrefix(dir + "/") { return true }
        #if os(macOS)
        // `resolvingSymlinksInPath` drops a leading "/private" only when the path exists,
        // so an existing directory loses it while the not-yet-created file inside it keeps
        // it — and every first write into /private/… is misread as an escape. Retry with
        // the prefix stripped from the nonexistent side only: such a path still begins
        // with the configured directory string, so this cannot admit a real traversal.
        if full.hasPrefix("/private/"), !FileManager.default.fileExists(atPath: full) {
            let stripped = String(full.dropFirst("/private".count))
            return stripped == dir || stripped.hasPrefix(dir + "/")
        }
        #endif
        return false
    }
}
