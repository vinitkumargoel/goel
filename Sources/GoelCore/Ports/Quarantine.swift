import Foundation
#if os(macOS)
import CoreServices
#endif

/// Sets `com.apple.quarantine` on downloaded payloads. The browser extension cancels the browser's
/// own download and re-fetches it here, so without this a hostile `.dmg`/`.pkg`/`.command` opens with
/// no Gatekeeper or XProtect check at all. Linux has no equivalent, so it is a no-op there.
public enum Quarantine {

    public static let agentName = "Goel°"

    /// Directories are marked recursively (multi-file torrents, auto-extract output). Best effort: returns
    /// how many items couldn't be flagged, so the caller can say so once rather than per file.
    /// A top-level symlink is skipped: setting the attribute follows it, onto a file outside the payload.
    @discardableResult
    public static func mark(_ url: URL, sourceURL: URL?, referrer: URL?) -> Int {
        #if os(macOS)
        guard !isSymbolicLink(url) else { return 0 }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let properties = quarantineProperties(sourceURL: sourceURL, referrer: referrer)
        var failed = markOne(url, properties) ? 0 : 1
        guard isDir.boolValue,
              let walker = FileManager.default.enumerator(
                  at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return failed }
        for case let child as URL in walker {
            // Setting the attribute follows a link, which would tag a file outside the payload.
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            if !markOne(child, properties) { failed += 1 }
        }
        return failed
        #else
        return 0
        #endif
    }

    /// A real folder (not a link to one): marking it means a walk, which callers keep off their actor.
    public static func isDirectoryTree(_ url: URL) -> Bool {
        guard !isSymbolicLink(url) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    /// Userinfo is stripped: the xattr is world-readable metadata and must not carry a password.
    static func scrubbed(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard url.user != nil || url.password != nil,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.user = nil
        c.password = nil
        return c.url
    }

    #if os(macOS)
    static func quarantineProperties(sourceURL: URL?, referrer: URL?) -> [String: Any] {
        var props: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        if let data = scrubbed(sourceURL) { props[kLSQuarantineDataURLKey as String] = data }
        if let origin = scrubbed(referrer) { props[kLSQuarantineOriginURLKey as String] = origin }
        return props
    }

    private static func markOne(_ url: URL, _ properties: [String: Any]) -> Bool {
        var target = url
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            GoelLog.scheduler.error("Couldn’t set the quarantine flag", .path(url.path),
                                    .detail(String(describing: error)))
            return false
        }
    }
    #endif
}
