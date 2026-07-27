import Foundation

/// Everything the server will tell us about one remote item — the backing for a
/// Get Info panel.
public struct SFTPAttributes: Sendable, Hashable {
    public var exists: Bool
    public var isDirectory: Bool
    /// Whether the item ITSELF is a symbolic link (lstat semantics), so a link is
    /// never quietly reported as the thing it points at.
    public var isSymlink: Bool
    public var size: Int64
    public var modified: Date?
    public var permissions: UInt32
    public var ownerID: UInt32
    public var groupID: UInt32

    public init(exists: Bool, isDirectory: Bool, isSymlink: Bool, size: Int64,
                modified: Date?, permissions: UInt32, ownerID: UInt32, groupID: UInt32) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.ownerID = ownerID
        self.groupID = groupID
    }

    /// The permission bits alone, without the file-type bits `st_mode` also
    /// carries.
    public var mode: UInt32 { permissions & 0o7777 }

    /// The mode as `ls` writes it: `rwxr-xr-x`, with setuid/setgid/sticky folded
    /// into the execute column the way `ls` does.
    public var modeString: String { SFTPPermissions.string(for: mode) }

    /// The mode as four octal digits, which is how people actually type it.
    public var octalString: String { String(format: "%04o", mode) }
}

/// Free and total capacity of a remote volume.
public struct SFTPVolumeSpace: Sendable, Hashable {
    /// Total size of the filesystem.
    public var totalBytes: Int64
    /// What is available to *this* user — `f_bavail`, not `f_bfree`, so the
    /// root-only reserve isn't counted as space the user can write into.
    public var freeBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    /// Fraction of the volume in use, or nil when the total is unknown.
    public var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
}

/// Rendering and parsing of POSIX permission bits.
public enum SFTPPermissions {

    /// `rwxr-xr-x`-style rendering of the low 12 bits.
    ///
    /// setuid, setgid and the sticky bit replace the corresponding execute
    /// character — `s`/`t` when execute is also set, `S`/`T` when it is not —
    /// which is the convention `ls` uses and therefore the one people can read
    /// without translating.
    public static func string(for mode: UInt32) -> String {
        var out = ""
        let triples: [(read: UInt32, write: UInt32, execute: UInt32, special: UInt32, letter: Character)] = [
            (0o400, 0o200, 0o100, 0o4000, "s"),
            (0o040, 0o020, 0o010, 0o2000, "s"),
            (0o004, 0o002, 0o001, 0o1000, "t"),
        ]
        for t in triples {
            out.append(mode & t.read != 0 ? "r" : "-")
            out.append(mode & t.write != 0 ? "w" : "-")
            if mode & t.special != 0 {
                let letter = String(t.letter)
                out.append(mode & t.execute != 0 ? letter : letter.uppercased())
            } else {
                out.append(mode & t.execute != 0 ? "x" : "-")
            }
        }
        return out
    }

    /// Parse a 3- or 4-digit octal mode as typed by a person. Returns nil for
    /// anything that isn't one, so a typo can never be applied as a *different*
    /// valid mode.
    public static func parse(octal text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(trimmed.count),
              trimmed.allSatisfy({ ("0"..."7").contains($0) }),
              let value = UInt32(trimmed, radix: 8) else { return nil }
        return value
    }

    /// Flip one bit of a mode — what a permissions checkbox does.
    public static func setting(_ mode: UInt32, bit: UInt32, on: Bool) -> UInt32 {
        on ? (mode | bit) : (mode & ~bit)
    }
}
