import Foundation

/// The outcome of enumerating a directory, keeping "listed successfully, found
/// nothing" distinct from "could not list".
///
/// The distinction is load-bearing. An overwrite check that folds a failed
/// listing into an empty set reads as "no conflicts", and the transfer that
/// follows opens every destination with `LIBSSH2_FXF_TRUNC` — destroying files
/// the user was never asked about. A directory we could not read is not an
/// empty directory.
public enum DirectoryListing: Sendable, Equatable {
    case names(Set<String>)
    case unavailable
}

/// Decides which items of an upload batch land on a free name and which collide
/// with something already at the destination.
public enum SFTPOverwritePlan {

    /// Split `names` (in batch order) into the indices that are free and the
    /// indices that collide — or nil when the destination could not be listed, in
    /// which case nothing may be sent because a name that looks free might not be.
    ///
    /// A name collides if the destination already holds it *or* if an earlier item
    /// in the same batch already claimed it: two picked files sharing a last path
    /// component (two "photo.jpg" from different folders) would otherwise both be
    /// "free" and race two writers onto one remote path.
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

    /// The name a *retried* transfer may write in a destination that currently
    /// holds `listing` — the name it already had when that is still free, a uniqued
    /// sibling when something else has taken it since, or nil when the destination
    /// could not be listed and therefore nothing may be written at all.
    ///
    /// A retry replays a decision that was made when the destination looked
    /// different. A failed download deletes its partial file and its row stops
    /// reserving the name, so by the time Retry is clicked that path may belong to
    /// a *different*, completed transfer — and the transfer opens its destination
    /// with truncation, so replaying blind destroys it. Nor is the collision
    /// exotic: every remote dotfile sanitizes to the same literal `download`, so
    /// two of them into one folder collide by default.
    ///
    /// `listing` must already include the names other in-flight transfers have
    /// reserved but not yet created, for the same reason ``split(names:against:)``
    /// tracks its batch: a queued destination is taken even though nothing is on
    /// disk yet.
    public static func retryName(_ current: String,
                                 against listing: DirectoryListing) -> String? {
        guard case .names(let existing) = listing else { return nil }
        return SFTPBrowserPaths.uniqueName(current, existing: existing)
    }
}
