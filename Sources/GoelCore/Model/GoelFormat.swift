import Foundation

/// The one place sizes, rates and durations become text, so the GUI, CLI, portal and error
/// strings agree with each other and with Finder (decimal units, the user's locale).
public enum GoelFormat {

    /// Finder-compatible: `.file` is decimal (1 KB = 1,000 bytes) and localised ("1,5 GB").
    public static func bytes(_ count: Int64) -> String {
        byteLock.lock()
        defer { byteLock.unlock() }
        return byteFormatter.string(fromByteCount: count)
    }

    /// Bytes per second; a zero or negative rate is "—", never "Zero KB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1,
              bytesPerSecond < Double(Int64.max) else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// Two most significant units, abbreviated per locale: "1h 30m", "45s", "2d 3h".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        #if os(Linux)
        // corelibs' DateComponentsFormatter is largely unimplemented and traps; stay manual there.
        return manualDuration(seconds)
        #else
        durationLock.lock()
        defer { durationLock.unlock() }
        // `.dropAll` renders zero as "", which would leave a blank cell.
        guard seconds.rounded() >= 1,
              let text = durationFormatter.string(from: seconds.rounded()), !text.isEmpty
        else { return manualDuration(seconds) }
        return text
        #endif
    }

    /// Locale-free fallback with the same shape as the abbreviated formatter's English output.
    static func manualDuration(_ seconds: TimeInterval) -> String {
        var remaining = Int64(seconds.rounded())
        let units: [(Int64, String)] = [(86_400, "d"), (3_600, "h"), (60, "m"), (1, "s")]
        var parts: [String] = []
        for (size, suffix) in units where parts.count < 2 {
            let value = remaining / size
            if value > 0 || (size == 1 && parts.isEmpty) {
                parts.append("\(value)\(suffix)")
                remaining -= value * size
            }
        }
        return parts.joined(separator: " ")
    }

    // Formatters are costly to build and these run per row per tick; the locks keep the shared
    // instances safe from the actors and the main thread that all format concurrently.
    private static let byteLock = NSLock()
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    #if !os(Linux)
    private static let durationLock = NSLock()
    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f
    }()
    #endif
}
