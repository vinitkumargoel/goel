import Foundation
#if os(macOS)
import CoreServices
#endif

/// Sets `com.apple.quarantine` on downloaded payloads. The browser extension cancels the browser's
/// own download and re-fetches it here, so without this a hostile `.dmg`/`.pkg`/`.command` opens with
/// no Gatekeeper or XProtect check at all. Linux has no equivalent, so it is a no-op there.
public enum Quarantine {

    public static let agentName = "Goel°"

    /// Directories are marked recursively (multi-file torrents, auto-extract output). Best effort:
    /// a failure is logged, never fatal — the file is already on disk either way.
    public static func mark(_ url: URL, sourceURL: URL?, referrer: URL?) {
        #if os(macOS)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let properties = quarantineProperties(sourceURL: sourceURL, referrer: referrer)
        markOne(url, properties)
        guard isDir.boolValue,
              let walker = FileManager.default.enumerator(
                  at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let child as URL in walker {
            // Setting the attribute follows a link, which would tag a file outside the payload.
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            markOne(child, properties)
        }
        #endif
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

    private static func markOne(_ url: URL, _ properties: [String: Any]) {
        var target = url
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do {
            try target.setResourceValues(values)
        } catch {
            GoelLog.scheduler.error("Couldn’t set the quarantine flag", .path(url.path),
                                    .detail(String(describing: error)))
        }
    }
    #endif
}
