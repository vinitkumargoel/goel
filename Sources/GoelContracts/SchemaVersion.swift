import Foundation

/// Version of the cross-language contract defined by `GoelContracts` — the domain
/// model, the engine-seam protocols, and the `Wire` request/response DTOs.
///
/// Bump this whenever a change to those shapes would break a client compiled
/// against an older version: a renamed or removed field, a changed JSON key, or a
/// changed enum wire-token. A companion client (the browser portal, a future
/// Android build, or the golden-JSON conformance fixtures) reads this to detect a
/// contract revision it cannot speak. This is distinct from the persistence-store
/// migration version, which tracks the on-disk SQLite schema.
public enum GoelContract {
    /// Current contract / wire-DTO schema version. Starts at 1.
    public static let schemaVersion = 1
}
