import Foundation

/// The byte-count assertion for a transfer that signalled success.
///
/// A stream ending is not the same as the whole file arriving: SFTP reports EOF
/// identically whether the server ran out of file or the connection ran out of
/// bytes, so a short transfer has to be checked explicitly rather than inferred
/// from the read loop finishing. Without it a truncated file settles as
/// "finished" and the row paints 100%.
public enum TransferCompletion {

    /// Bytes still owed when a transfer signalled success, or nil when there is
    /// nothing to assert. `expected <= 0` means the size was never known (an
    /// unstatable remote file, a `/proc`-style zero-length source), and
    /// over-delivery means the source grew mid-transfer — neither is a truncation.
    public static func shortfall(expected: Int64, written: Int64) -> Int64? {
        guard expected > 0, written < expected else { return nil }
        return expected - written
    }
}
