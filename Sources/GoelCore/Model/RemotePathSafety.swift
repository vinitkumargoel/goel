import Foundation

/// Pure string validation for the *remote* side of an upload — runs before any session, so a hostile destination is refused without authenticating.
public enum RemotePathSafety {

    /// Why a remote path was refused; `message` is shown to the user verbatim.
    public enum Rejection: Error, Sendable, Equatable, Hashable {
        case empty, notAbsolute, traversal, emptyComponent
        case controlCharacter, nameTooLong, pathTooLong, unusableName

        public var message: String {
            switch self {
            case .empty: return "The destination folder is empty. Use \".\" for the login home folder."
            case .notAbsolute: return "The destination folder must start with \"/\", or be \".\" for the login home folder."
            case .traversal: return "The destination folder contains \"..\", which could place the file outside the folder you chose."
            case .emptyComponent: return "The destination folder has an empty path segment (\"//\")."
            case .controlCharacter: return "The destination folder contains control characters."
            case .nameTooLong: return "The file name is too long for the server (limit \(maxNameBytes) bytes)."
            case .pathTooLong: return "The full remote path is too long for the server (limit \(maxPathBytes) bytes)."
            case .unusableName: return "The file name has no usable characters for a remote filesystem."
            }
        }
    }

    /// Linux limits; a stricter server fails the upload cleanly and keeps the local copy.
    public static let maxNameBytes = 255
    public static let maxPathBytes = 4096

    /// Bytes reserved for the `.goel-XXXXXXXX.part` suffix so the temporary name still fits.
    static let temporarySuffixBudget = 24

    // MARK: Directories

    /// Validate an upload destination: `"."` (login home) or a server-absolute path, every component checked.
    public static func validateDirectory(_ raw: String) -> Result<String, Rejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if let bad = firstControlCharacterRejection(trimmed) { return .failure(bad) }
        guard trimmed.utf8.count <= maxPathBytes else { return .failure(.pathTooLong) }

        // Requiring "." to be written explicitly is what makes a blank string a rejection rather than a silent drop into $HOME.
        if trimmed == "." { return .success(".") }
        guard trimmed.hasPrefix("/") else { return .failure(.notAbsolute) }

        // Every component, not just the leaf: one `..` anywhere escapes the tree, and a deep path is where it would go unnoticed.
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        for (i, component) in components.enumerated() {
            if i == 0 { continue }                                    // the empty string before the root "/"
            if component.isEmpty {
                if i == components.count - 1 { continue }             // a trailing slash is a normal spelling; an interior "//" is not
                return .failure(.emptyComponent)
            }
            if component == ".." || component == "." { return .failure(.traversal) }
            if component.utf8.count > maxNameBytes { return .failure(.nameTooLong) }
        }

        // Drop a trailing slash so joins produce one separator and two spellings compare equal.
        var normalized = trimmed
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        return .success(normalized.precomposedStringWithCanonicalMapping)
    }

    // MARK: File names

    /// Reduce a name to something a POSIX server accepts, or nil if nothing usable survives.
    public static func sanitizedComponent(_ raw: String) -> String? {
        // macOS hands out NFD, Linux stores NFC — normalising is what makes a later conflict check compare like with like.
        let normalized = raw.precomposedStringWithCanonicalMapping

        // Take the last component so an embedded "../" collapses to a plain name instead of steering the write.
        var name = String(normalized.split(separator: "/").last ?? "")
        // Only `/`, NUL and control characters are actually unsafe; `:` `?` `*` are legal on Linux and rewriting them would rename the user's file for nothing.
        name = String(name.unicodeScalars.filter { $0.properties.generalCategory != .control && $0 != "\0" })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // A leading "-" reads as a flag to any command-line tool run on the server later.
        while name.hasPrefix("-") { name.removeFirst() }

        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return clampNameLength(name)
    }

    /// Clamp to `maxNameBytes` keeping the extension, leaving room for the `.part` suffix.
    static func clampNameLength(_ name: String) -> String {
        let budget = maxNameBytes - temporarySuffixBudget
        guard name.utf8.count > budget else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let extBudget = (!ext.isEmpty && ext.utf8.count <= 16) ? ext.utf8.count + 1 : 0
        guard extBudget > 0 else { return truncateUTF8(name, toBytes: budget) }
        return truncateUTF8(ns.deletingPathExtension, toBytes: max(1, budget - extBudget)) + "." + ext
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

    // MARK: Relative paths (multi-file payloads)

    /// Validate a payload-relative path like `season 1/ep01.mkv` — every component of every nested path, since engine-declared torrent/HLS paths are attacker-influenced in exactly this shape.
    public static func validateRelativePath(_ raw: String) -> Result<String, Rejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if let bad = firstControlCharacterRejection(trimmed) { return .failure(bad) }
        guard !trimmed.hasPrefix("/") else { return .failure(.traversal) }

        var sanitized: [String] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if component == ".." { return .failure(.traversal) }
            if component == "." { continue }
            guard let safe = sanitizedComponent(String(component)) else { return .failure(.unusableName) }
            sanitized.append(safe)
        }
        guard !sanitized.isEmpty else { return .failure(.unusableName) }
        return .success(sanitized.joined(separator: "/"))
    }

    // MARK: Joining

    /// Join an already-validated directory and relative path; does not re-validate either.
    public static func join(directory: String, relative: String) -> Result<String, Rejection> {
        let joined: String
        if directory == "." { joined = relative }
        else if directory.hasSuffix("/") { joined = directory + relative }
        else { joined = directory + "/" + relative }
        guard joined.utf8.count <= maxPathBytes else { return .failure(.pathTooLong) }
        return .success(joined)
    }

    /// Lexical containment for remote paths — used to check a server-supplied `realpath` against the folder the user actually picked.
    public static func isContained(_ path: String, within root: String) -> Bool {
        guard root != "." else { return true }   // home: nothing to compare against
        var normalizedRoot = root
        while normalizedRoot.count > 1 && normalizedRoot.hasSuffix("/") { normalizedRoot.removeLast() }
        return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
    }

    // MARK: Helpers

    /// Control characters in a *path* are refused, not stripped: a path is structural, and rewriting it would change where the file lands.
    private static func firstControlCharacterRejection(_ s: String) -> Rejection? {
        for scalar in s.unicodeScalars where scalar.properties.generalCategory == .control || scalar == "\0" {
            return .controlCharacter
        }
        return nil
    }

    /// The in-flight name for a file; the per-task token stops two uploads of the same name sharing one temporary.
    public static func temporaryName(for name: String, token: String) -> String {
        "\(name).goel-\(token).part"
    }
}
