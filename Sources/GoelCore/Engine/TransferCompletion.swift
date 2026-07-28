import Foundation

/// The byte-count assertion for a transfer that signalled success. SFTP reports EOF identically for
/// "end of file" and "connection died", so without an explicit check a truncated file paints 100%.
public enum TransferCompletion {

    /// Bytes still owed after a success signal, or nil when there is nothing to assert: `expected <= 0`
    /// means the size was never known, over-delivery means the source grew — neither is truncation.
    public static func shortfall(expected: Int64, written: Int64) -> Int64? {
        guard expected > 0, written < expected else { return nil }
        return expected - written
    }
}
