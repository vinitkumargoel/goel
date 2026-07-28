import Foundation

/// SFTP reports EOF identically for "end of file" and "connection died": without this a truncated file paints 100%.
public enum TransferCompletion {

    public static func shortfall(expected: Int64, written: Int64) -> Int64? {
        guard expected > 0, written < expected else { return nil }
        return expected - written
    }
}
