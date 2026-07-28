import Foundation

/// Directory enumeration outcome, keeping "listed, found nothing" distinct from "could not list": folding
/// a failure into an empty set reads as "no conflicts" and `LIBSSH2_FXF_TRUNC` then destroys real files.
public enum DirectoryListing: Sendable, Equatable {
    case names(Set<String>)
    case unavailable
}

/// Decides which items of an upload batch land on a free name and which collide
/// with something already at the destination.
public enum SFTPOverwritePlan {

    /// Split `names` (batch order) into free vs colliding indices; nil when the listing failed, since a
    /// name that looks free might not be. Earlier batch items claim names too — two "photo.jpg" would race.
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

    /// Name a *retried* transfer may write: its own if still free, a uniqued sibling if taken since, nil if
    /// unlistable — retries truncate. `listing` must include names reserved by in-flight transfers.
    public static func retryName(_ current: String,
                                 against listing: DirectoryListing) -> String? {
        guard case .names(let existing) = listing else { return nil }
        return SFTPBrowserPaths.uniqueName(current, existing: existing)
    }
}
