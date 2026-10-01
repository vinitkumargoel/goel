import Foundation
import GoelCore

/// The review step's rename: the user edits the base, the extension stays as the server gave it.
enum FileNameEdit {

    /// "a.tar.gz" keeps "gz" as its extension, the same split Finder shows.
    static func split(_ name: String) -> (base: String, ext: String) {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else { return (name, "") }
        return (String(name.dropLast(ext.count + 1)), ext)
    }

    /// The final name, made safe for a path; an emptied field falls back to the original.
    static func name(base: String?, original: String) -> String {
        guard let base else { return original }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return original }
        let ext = split(original).ext
        let joined = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        return PathSafety.sanitizedName(joined, fallback: original)
    }

    /// The warning under the name when that file is already in the folder, in the words of
    /// Settings › General › When a file exists.
    static func existingFileWarning(name: String, in folder: String, reaction: String,
                                    fileManager: FileManager = .default) -> String? {
        let path = (folder as NSString).appendingPathComponent(name)
        guard fileManager.fileExists(atPath: path) else { return nil }
        return reaction == "overwrite"
            ? L10n.t("“%@” is already in this folder and will be replaced (Settings › When a file exists: Overwrite).", name)
            : L10n.t("“%@” is already in this folder, so both are kept by appending “(1)” (Settings › When a file exists: Rename).", name)
    }
}
