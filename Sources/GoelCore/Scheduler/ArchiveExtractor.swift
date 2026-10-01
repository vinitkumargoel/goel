import Foundation

/// Auto-extract, bounded: one tool (`bsdtar`, which refuses absolute paths and `..`), a size cap
/// checked against the archive's own listing and again while it unpacks, a time limit, and a
/// private staging folder on the same volume so nothing half-unpacked or escaping is left behind.
public enum ArchiveExtractor {

    public enum Outcome: Equatable, Sendable {
        case extracted(String)
        case launchFailed
        case timedOut
        case tooLarge(cap: Int64)
        case failed
    }

    static let tool = "/usr/bin/bsdtar"
    /// However much room there is, a single archive never unpacks past this.
    public static let absoluteCap: Int64 = 50_000_000_000
    /// Left free on the volume so an extraction can't fill the disk the downloads still need.
    public static let freeSpaceMargin: Int64 = 2_000_000_000
    static let timeout: TimeInterval = 600
    static let pollInterval: TimeInterval = 0.5

    /// The smaller of 50 GB and the free space less a margin; unknown free space keeps 50 GB.
    public static func sizeCap(freeBytes: Int64?) -> Int64 {
        guard let freeBytes else { return absoluteCap }
        return max(0, min(absoluteCap, freeBytes - freeSpaceMargin))
    }

    /// Sums the sizes an `ls -l`-style `bsdtar -tvf` listing declares
    /// (`-rw-r--r--  0 user group  1234 Jan  1  2020 name`). Lines it can't read count as zero:
    /// the watchdog still measures what actually lands.
    public static func declaredBytes(inListing listing: String) -> Int64 {
        var total: Int64 = 0
        for line in listing.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 4, let size = Int64(fields[4]), size > 0 else { continue }
            let (sum, overflow) = total.addingReportingOverflow(size)
            total = overflow ? .max : sum
        }
        return total
    }

    /// "pack.zip extracted", then "pack.zip extracted 2", … so an earlier extraction is never merged into.
    static func uniqueTarget(for archive: String, in directory: String,
                             fileManager: FileManager = .default) -> String {
        let base = (archive as NSString).lastPathComponent + " extracted"
        var candidate = (directory as NSString).appendingPathComponent(base)
        var n = 2
        while fileManager.fileExists(atPath: candidate) {
            candidate = (directory as NSString).appendingPathComponent("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    /// Blocking; call from a detached task. `cap` overrides the free-space cap (tests).
    public static func extract(_ archive: String, into directory: String, cap: Int64? = nil) -> Outcome {
        let fm = FileManager.default
        let limit = cap ?? sizeCap(freeBytes: freeBytes(at: directory))
        guard let listing = run([tool, "-tvf", archive]) else { return .failed }
        guard declaredBytes(inListing: listing) <= limit else { return .tooLarge(cap: limit) }

        // Staged beside the destination (same volume, so the final move is a rename).
        let staging = (directory as NSString).appendingPathComponent(".goel-extract-\(UUID().uuidString)")
        do {
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        } catch {
            return .failed
        }
        let outcome = unpack(archive, into: staging, limit: limit)
        guard outcome == nil else {
            try? fm.removeItem(atPath: staging)
            return outcome ?? .failed
        }
        DownloadManager.quarantineExtractedEscapees(under: staging)
        let target = uniqueTarget(for: archive, in: directory)
        do {
            try fm.moveItem(atPath: staging, toPath: target)
        } catch {
            try? fm.removeItem(atPath: staging)
            return .failed
        }
        return .extracted(target)
    }

    /// nil when it finished cleanly; otherwise why it stopped.
    private static func unpack(_ archive: String, into staging: String, limit: Int64) -> Outcome? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-x", "-f", archive, "-C", staging]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .launchFailed }
        let started = Date()
        var lastMeasured = Date.distantPast
        while process.isRunning {
            Thread.sleep(forTimeInterval: pollInterval)
            if Date().timeIntervalSince(started) > timeout {
                process.terminate()
                process.waitUntilExit()
                return .timedOut
            }
            // Walking the tree costs something; every couple of seconds is enough to stop a bomb.
            if Date().timeIntervalSince(lastMeasured) >= 2 {
                lastMeasured = Date()
                if bytes(under: staging) > limit {
                    process.terminate()
                    process.waitUntilExit()
                    return .tooLarge(cap: limit)
                }
            }
        }
        if bytes(under: staging) > limit { return .tooLarge(cap: limit) }
        return process.terminationStatus == 0 ? nil : .failed
    }

    static func bytes(under folder: String) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.fileSizeKey],
            options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            total &+= Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func freeBytes(at directory: String) -> Int64? {
        #if os(macOS)
        let values = try? URL(fileURLWithPath: directory)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }

    /// stdout of a short listing run, or nil when it failed or ran past the time limit.
    private static func run(_ command: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
