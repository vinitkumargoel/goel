import Foundation
import GoelCore

/// The browser side of the extension bridge.
///
/// Browsers spawn the same GoelDownloader binary through a wrapper script that
/// adds `--native-messaging-host`; `main.swift` routes that invocation here
/// instead of starting the GUI. The protocol is WebExtensions native
/// messaging: a 4-byte little-endian length followed by that many bytes of
/// JSON, in both directions, over stdio.
///
/// Received URLs are validated through the normal source allowlist, spooled to
/// a user-only directory, and the GUI instance is poked (via a content-free
/// URL-scheme open) to drain the spool. The filesystem spool — not the
/// world-triggerable URL scheme — is the trust boundary, so spooled adds don't
/// need the web-origin confirmation banner.
///
/// A message may also carry the browser's `Cookie` header for that URL (the
/// extension only sends it when the user has explicitly granted the optional
/// `cookies` permission). That is what makes logged-in downloads work at all.
/// Cookies are credentials, so they are sanitised here, written to a `0600` file
/// inside the already-`0700` spool, expired after ``BrowserSpool/cookieMaxAge``,
/// and deleted the moment the app reads them. They are never logged and never
/// echoed back to the browser.
enum NativeMessagingHost {

    /// Longest message we'll read; native messaging caps host-bound messages
    /// at 4 GB but ours are one URL plus a cookie header, so anything huge is
    /// garbage (``CookieHeader/maxLength`` caps the cookie at 8 KiB regardless).
    private static let maxMessageBytes: UInt32 = 1 << 20

    /// Serve messages until the browser closes the pipe. Never returns early.
    static func runLoop() {
        while let message = readMessage() {
            handle(message)
        }
    }

    private static func handle(_ message: [String: Any]) {
        guard let raw = message["url"] as? String,
              let source = DownloadSource.parse(raw),
              // The spool auto-adds with no confirmation, so it must only carry
              // credential-free web-download schemes — never an `sftp:`/`ftp:`
              // link a web page could use to trigger an authenticated outbound
              // connection. (Those schemes are still allowed via the add box.)
              source.isBrowserCaptureSafe,
              // …and only at a host a *web page* is allowed to steer this app at.
              // The scheme check says nothing about the destination, so without
              // this a page could spool `http://127.0.0.1:<port>/…` and have the
              // app fetch a service on this machine that was deliberately never
              // exposed to the browser, with no user in the loop at all.
              Self.captureTargetAllowed(source) else {
            writeMessage(["ok": false, "error": "unsupported url"])
            return
        }
        // Cookies only ride with an http(s) capture — a magnet has no origin to
        // scope them to, so there is nothing they could safely be sent to.
        let scope: String? = URL(string: source.locator).flatMap(CookieHeader.scope(for:))
        let cookie = scope == nil ? nil : (message["cookie"] as? String).flatMap(CookieHeader.sanitized)
        let capture = BrowserCapture(
            locator: source.locator,
            referer: Self.sanitizedReferer(message["referrer"] as? String),
            cookieHeader: cookie,
            cookieHost: cookie == nil ? nil : scope
        )
        do {
            try BrowserSpool.enqueue(capture)
            pokeApp()
            // Report only *whether* cookies were accepted. Echoing the value (or
            // the names) back into the page's extension context would hand a
            // compromised extension a read-back oracle for HttpOnly cookies.
            writeMessage(["ok": true, "cookies": cookie != nil])
        } catch {
            writeMessage(["ok": false, "error": "spool write failed"])
        }
    }

    /// Whether a capture's fetch target is a host this app may be pointed at by a
    /// page. Same rule the network portal applies to a caller-supplied add, and for
    /// the same reason — neither caller is the person at the keyboard. A magnet
    /// names no host, so there is nothing to screen. This is the spelling-only
    /// check; the app re-screens the spool against resolved addresses when it
    /// drains it, which is where the blocking lookup belongs.
    private static func captureTargetAllowed(_ source: DownloadSource) -> Bool {
        guard let url = source.fetchTargetURL else { return true }
        return NetworkGuard.isAllowedRemoteAddTarget(url)
    }

    /// Keep a browser-supplied referrer only if it is a plain web URL of sane
    /// length and carries no header-splitting characters. The engine sends this
    /// verbatim as `Referer`, and the page that triggered the capture chose it.
    private static func sanitizedReferer(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.utf8.count <= 2048,
              !trimmed.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0.value == 0 }),
              let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return trimmed
    }

    /// Ask the running app (launching it if needed) to drain the spool. The
    /// URL carries nothing — see the trust-boundary note above.
    private static func pokeApp() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["goeldownloader://drain-browser-queue"]
        try? open.run()
        open.waitUntilExit()
    }

    // MARK: Wire format

    private static func readMessage() -> [String: Any]? {
        guard let lengthData = readExactly(4) else { return nil }
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        guard length > 0, length <= maxMessageBytes,
              let body = readExactly(Int(length)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func readExactly(_ count: Int) -> Data? {
        var buffer = Data()
        while buffer.count < count {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: count - buffer.count),
                  !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
        return buffer
    }

    private static func writeMessage(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(body.count).littleEndian
        let header = Data(bytes: &length, count: 4)
        try? FileHandle.standardOutput.write(contentsOf: header + body)
    }
}

/// One capture handed over by the browser: the URL, plus the request context the
/// page needed for it to work at all.
///
/// ``cookieHeader`` is a bearer credential. It lives in memory and in one `0600`
/// spool file that is deleted on read; it is never persisted with the task (see
/// ``DownloadTask/cookieHeader``) and never logged.
struct BrowserCapture: Sendable, Equatable {
    var locator: String
    /// The page the download was started from, for hosts that gate on `Referer`.
    var referer: String?
    /// A sanitised `Cookie` header value, or nil when the user hasn't granted the
    /// extension's optional cookie permission (the common case).
    var cookieHeader: String?
    /// The host ``cookieHeader`` was captured for; cookies go nowhere else.
    var cookieHost: String?

    init(locator: String, referer: String? = nil,
         cookieHeader: String? = nil, cookieHost: String? = nil) {
        self.locator = locator
        self.referer = referer
        self.cookieHeader = cookieHeader
        self.cookieHost = cookieHost
    }
}

/// The on-disk handoff between the native-messaging host process and the GUI
/// app (they are separate processes of the same binary).
enum BrowserSpool {

    /// Most spooled adds consumed per drain — a runaway feeder can't flood the
    /// queue in one tick; leftovers drain on the next poke or launch.
    private static let drainCap = 100

    /// How long a spooled cookie stays usable. The URL keeps forever — a capture
    /// made while the app was closed should still queue — but the *credential*
    /// attached to it is dropped once it is this old, so a laptop that sits shut
    /// for a week doesn't wake up with a stale session cookie on disk. An expired
    /// cookie is also useless: the session it belonged to has almost certainly
    /// rotated, and the download would fail with a confusing 403 either way.
    static let cookieMaxAge: TimeInterval = 60 * 60

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoelDownloader/BrowserQueue", isDirectory: true)
    }

    static func enqueue(locator: String) throws {
        try enqueue(BrowserCapture(locator: locator))
    }

    static func enqueue(_ capture: BrowserCapture) throws {
        let fm = FileManager.default
        // Restrict the spool to the owner (0700): this directory is a no-confirmation
        // command channel — any file dropped here queues a download — so it must not
        // be group/world-writable on a shared machine.
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(UUID().uuidString + ".json")
        var object: [String: Any] = ["url": capture.locator]
        if let referer = capture.referer { object["referer"] = referer }
        if let cookie = capture.cookieHeader { object["cookie"] = cookie }
        if let host = capture.cookieHost { object["cookieHost"] = host }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: file, options: .atomic)
        // The file can hold a session cookie, so tighten it past the process
        // umask. The enclosing directory is already 0700, so the brief post-write
        // window is not reachable by another user — this is the second lock.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Read, delete, and return the spooled locators (oldest first, capped).
    /// Compatibility shim for callers that only want URLs — it **discards** the
    /// captured referer and cookies, so a logged-in download added through it
    /// will fail. Prefer ``drainCaptures()``.
    static func drain() -> [String] {
        drainCaptures().map(\.locator)
    }

    /// Read, delete, and return the spooled captures (oldest first, capped).
    /// Cookies older than ``cookieMaxAge`` are stripped, the URL kept.
    static func drainCaptures() -> [BrowserCapture] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let ordered = files
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
            .prefix(drainCap)
        var captures: [BrowserCapture] = []
        for file in ordered {
            if let data = try? Data(contentsOf: file),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let url = object["url"] as? String {
                let written = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                let cookieIsFresh = Date().timeIntervalSince(written) <= cookieMaxAge
                // Re-sanitise on the way out: the spool file is only as trustworthy
                // as its 0700 directory, and re-validating is cheap.
                let cookie = cookieIsFresh
                    ? (object["cookie"] as? String).flatMap(CookieHeader.sanitized) : nil
                captures.append(BrowserCapture(
                    locator: url,
                    referer: object["referer"] as? String,
                    cookieHeader: cookie,
                    cookieHost: cookie == nil ? nil : object["cookieHost"] as? String
                ))
            }
            try? fm.removeItem(at: file)
        }
        return captures
    }
}
