import Foundation

enum CLIError: Error {
    case message(String)
    case needsRoot
    case noSystemd
    case notInstalled(missing: String)
    case portalUnreachable(port: Int, reason: String)
    /// HTTP 403 — the portal explained why; `goel add` maps this to the download-failed exit.
    case forbidden(String)
    case usage(String)

    var text: String {
        switch self {
        case .message(let m):
            return m
        case .forbidden(let m):
            return m
        case .needsRoot:
            return """
                this needs root — the config file and the API token are readable only by root.
                Try again with sudo.
                """
        case .noSystemd:
            return """
                no systemd on this machine, so there is no managed service.
                Run the daemon yourself instead — `GoelDaemon` in the foreground picks up
                the same configuration (docs/cli.md → “Running without systemd”).
                """
        case .notInstalled(let missing):
            return """
                \(missing) is missing — Goel° does not look installed on this machine.
                Linux (service install):
                    curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh
                Portable (macOS, or no root): start `GoelDaemon`, then point goel at it with
                `goel config set port <port>` / `goel config set token <token>` — or export
                GOEL_PORT and GOEL_TOKEN. Details: docs/cli.md.
                """
        case .portalUnreachable(let port, let reason):
            return """
                can’t reach the portal on 127.0.0.1:\(port) — \(reason)
                The daemon may be stopped or still starting. Check `goel status`, then `goel logs`.
                """
        case .usage(let m):
            return m
        }
    }
}

/// The CLI's exit-code contract — documented in docs/cli.md and `goel help`, so
/// agents can branch on them. Codes must never be renumbered, only added to.
enum ExitCode {
    static let ok: Int32 = 0
    /// Runtime trouble: portal unreachable, HTTP error, bad reply.
    static let error: Int32 = 1
    /// The command line itself was wrong.
    static let usage: Int32 = 2
    /// The download did not (fully) happen: a source was refused, nothing was added,
    /// or a waited task failed — even when sibling downloads in the same run saved.
    static let downloadFailed: Int32 = 3
    /// --timeout expired while a waited download was still running; it continues server-side.
    static let timedOut: Int32 = 4
    /// Ctrl-C during a wait — the download itself keeps going. 128 + SIGINT, as shells report it.
    static let detached: Int32 = 130
}

enum Out {
    static let colorful: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return false }
        return isatty(STDOUT_FILENO) == 1
    }()

    static func paint(_ text: String, _ code: String) -> String {
        colorful ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ t: String) -> String { paint(t, "1") }
    static func green(_ t: String) -> String { paint(t, "32") }
    static func red(_ t: String) -> String { paint(t, "31") }
    static func amber(_ t: String) -> String { paint(t, "33") }
    static func dim(_ t: String) -> String { paint(t, "2") }

    static func line(_ text: String = "") { print(text) }

    /// Remote-controlled text (filenames, error strings, paths built from them) passes
    /// through here before it reaches the terminal. A hostile server can put raw ANSI/OSC
    /// escapes in a Content-Disposition name or magnet dn=; unfiltered, those can retitle
    /// the window, poison the clipboard, or fake a prompt. C0 controls, DEL, and C1
    /// controls are dropped; printable text (any script) passes through untouched.
    static func safe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
        }))
    }

    /// Machine output: raw bytes plus one trailing newline, nothing painted.
    static func data(_ body: Data) {
        FileHandle.standardOutput.write(body)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data(("goel: " + text + "\n").utf8))
    }

    static func note(_ text: String) {
        FileHandle.standardError.write(Data((paint("note: ", "33") + text + "\n").utf8))
    }

    static func pairs(_ rows: [(String, String)]) {
        let width = rows.map(\.0.count).max() ?? 0
        for (key, value) in rows {
            let padding = String(repeating: " ", count: width - key.count)
            print("  \(dim(key))\(padding)  \(value)")
        }
    }

    static func table(headers: [String], rows: [[String]], maxWidths: [Int?]) {
        guard !rows.isEmpty else { return }
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        for (index, cap) in maxWidths.enumerated() where index < widths.count {
            if let cap { widths[index] = min(widths[index], cap) }
        }
        func render(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                let clipped = cell.count > widths[index]
                    ? String(cell.prefix(max(0, widths[index] - 1))) + "…"
                    : cell
                let padding = String(repeating: " ", count: widths[index] - clipped.count)
                return index == cells.count - 1 ? clipped : clipped + padding
            }.joined(separator: "  ")
        }
        print("  " + dim(render(headers)))
        for row in rows { print("  " + render(row)) }
    }

    /// Decimal units like Finder and GoelCore's `GoelFormat`, so `goel` and the app agree on a
    /// file's size (1024-based, the CLI said "1.4 GB" where the GUI said "1.5 GB"). A copy rather
    /// than a call: GoelCLI links nothing, so `goel doctor` runs even when GoelCore can't load.
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var scaled = value, index = 0
        while scaled >= 1000, index < units.count - 1 { scaled /= 1000; index += 1 }
        if index == 0 { return Int(scaled) == 1 ? "1 byte" : "\(Int(scaled)) bytes" }
        // Same precision rule as ByteCountFormatter(.file): whole KB, one decimal above.
        return index == 1 ? "\(Int(scaled.rounded())) KB" : String(format: "%.1f %@", scaled, units[index])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "—" : bytes(bytesPerSecond) + "/s"
    }

    /// Comfortably inside Int64 (≈ 285 billion years); anything longer is noise anyway.
    static let maxDurationSeconds: Double = 9e18

    /// Two most significant units — the shape `GoelFormat.duration` prints in English.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        // Clamped below Int64.max: `Int64(_:)` traps on a Double it can't represent (a bogus ETA).
        var remaining = Int64(min(seconds.rounded(), maxDurationSeconds))
        var parts: [String] = []
        for (size, suffix) in [(Int64(86_400), "d"), (3_600, "h"), (60, "m"), (1, "s")] where parts.count < 2 {
            let value = remaining / size
            if value > 0 || (size == 1 && parts.isEmpty) {
                parts.append("\(value)\(suffix)")
                remaining -= value * size
            }
        }
        return parts.joined(separator: " ")
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }
}
