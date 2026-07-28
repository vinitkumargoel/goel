import Foundation

/// Keeps "listed nothing" distinct from "could not list": an empty set reads as no conflicts and `LIBSSH2_FXF_TRUNC` then destroys real files.
public enum DirectoryListing: Sendable, Equatable {
    case names(Set<String>)
    case unavailable
}

public enum SFTPOverwritePlan {

    /// Nil when the listing failed — a name that looks free might not be; earlier batch items claim names too.
    public static func split(names: [String],
                             against listing: DirectoryListing) -> (free: [Int], colliding: [Int])? {
        guard case .names(let existing) = listing else { return nil }
        var taken = existing
        var free: [Int] = []
        var colliding: [Int] = []
        for (index, name) in names.enumerated() {
            if taken.contains(name) {
                colliding.append(index)
            } else {
                free.append(index)
                taken.insert(name)
            }
        }
        return (free, colliding)
    }

    /// Nil when unlistable, because retries truncate; `listing` must include names reserved by in-flight transfers.
    public static func retryName(_ current: String,
                                 against listing: DirectoryListing) -> String? {
        guard case .names(let existing) = listing else { return nil }
        return SFTPBrowserPaths.uniqueName(current, existing: existing)
    }
}
