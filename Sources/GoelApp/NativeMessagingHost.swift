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
enum NativeMessagingHost {

    /// Longest message we'll read; native messaging caps host-bound messages
    /// at 4 GB but ours are one URL, so anything huge is garbage.
    private static let maxMessageBytes: UInt32 = 1 << 20

    /// Serve messages until the browser closes the pipe. Never returns early.
    static func runLoop() {
        while let message = readMessage() {
            handle(message)
        }
    }

    private static func handle(_ message: [String: Any]) {
        guard let raw = message["url"] as? String,
              let source = DownloadSource.parse(raw) else {
            writeMessage(["ok": false, "error": "unsupported url"])
            return
        }
        do {
            try BrowserSpool.enqueue(locator: source.locator)
            pokeApp()
            writeMessage(["ok": true])
        } catch {
            writeMessage(["ok": false, "error": "spool write failed"])
        }
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

/// The on-disk handoff between the native-messaging host process and the GUI
/// app (they are separate processes of the same binary).
enum BrowserSpool {

    /// Most spooled adds consumed per drain — a runaway feeder can't flood the
    /// queue in one tick; leftovers drain on the next poke or launch.
    private static let drainCap = 100

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoelDownloader/BrowserQueue", isDirectory: true)
    }

    static func enqueue(locator: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".json")
        let data = try JSONSerialization.data(withJSONObject: ["url": locator])
        try data.write(to: file, options: .atomic)
    }

    /// Read, delete, and return the spooled locators (oldest first, capped).
    static func drain() -> [String] {
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
        var locators: [String] = []
        for file in ordered {
            if let data = try? Data(contentsOf: file),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let url = object["url"] as? String {
                locators.append(url)
            }
            try? fm.removeItem(at: file)
        }
        return locators
    }
}
