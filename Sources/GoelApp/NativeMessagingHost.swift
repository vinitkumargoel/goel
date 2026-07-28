import Foundation
import GoelCore

/// Trust boundary: browser input. URLs are allowlisted and spooled to a 0700 dir; cookies are sanitised, 0600, expiring, deleted on read.
enum NativeMessagingHost {

    /// 1 MiB, not the protocol's 4 GB: ours are one URL plus a cookie header, so anything larger is hostile or garbage.
    private static let maxMessageBytes: UInt32 = 1 << 20

    static func runLoop() {
        while let message = readMessage() {
            handle(message)
        }
    }

    private static func handle(_ message: [String: Any]) {
        guard let raw = message["url"] as? String,
              let source = DownloadSource.parse(raw),
              // The spool auto-adds with no confirmation: web-download schemes only, never an `sftp:`/`ftp:` link a page could use to trigger an authenticated connection.
              source.isBrowserCaptureSafe,
              // SSRF: without this a page could spool `http://127.0.0.1:<port>/…` and have the app fetch a service never exposed to the browser.
              Self.captureTargetAllowed(source) else {
            writeMessage(["ok": false, "error": "unsupported url"])
            return
        }
        // Cookies only ride with an http(s) capture: a magnet has no origin to scope them to.
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
            // Report only *whether* cookies were accepted: echoing values or names would give a compromised extension a read-back oracle for HttpOnly cookies.
            writeMessage(["ok": true, "cookies": cookie != nil])
        } catch {
            writeMessage(["ok": false, "error": "spool write failed"])
        }
    }

    /// Spelling-only screen; the app re-screens against resolved addresses when it drains.
    private static func captureTargetAllowed(_ source: DownloadSource) -> Bool {
        guard let url = source.fetchTargetURL else { return true }
        return NetworkGuard.isAllowedRemoteAddTarget(url)
    }

    /// The engine sends this verbatim as `Referer`: reject header-splitting characters and non-web schemes.
    private static func sanitizedReferer(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.utf8.count <= 2048,
              !trimmed.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0.value == 0 }),
              let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return trimmed
    }

    /// The URL carries no data; the 0700 spool is the only channel.
    private static func pokeApp() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["goeldownloader://drain-browser-queue"]
        try? open.run()
        open.waitUntilExit()
    }

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

/// ``cookieHeader`` is a bearer credential — one 0600 spool file, deleted on read, never logged.
struct BrowserCapture: Sendable, Equatable {
    var locator: String
    var referer: String?
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

enum BrowserSpool {

    /// Caps one tick so a runaway feeder can't flood the queue; leftovers drain on the next poke.
    private static let drainCap = 100

    /// Credential expiry: the URL keeps forever, the cookie is dropped once this old so a machine shut for a week doesn't wake with a live session cookie on disk.
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
        // 0700: this directory is a no-confirmation command channel and must not be group/world-writable.
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
        // The file can hold a session cookie: tighten past the process umask.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Shim: **discards** referer and cookies, so a logged-in download added through it fails — prefer ``drainCaptures()``.
    static func drain() -> [String] {
        drainCaptures().map(\.locator)
    }

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
                // Re-sanitise on the way out: the spool file is only as trustworthy as its 0700 directory.
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
