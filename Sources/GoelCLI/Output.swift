import Foundation

enum CLIError: Error {
    case message(String)
    case needsRoot
    case noSystemd
    case notInstalled(missing: String)
    case portalUnreachable(port: Int, reason: String)
    case usage(String)

    var text: String {
        switch self {
        case .message(let m):
            return m
        case .needsRoot:
            return """
                this needs root — the config file and the API token are readable only by root.
                Try again with sudo.
                """
        case .noSystemd:
            return """
                no systemd on this machine, so there is no service to manage.
                Run the daemon directly instead: \(Layout.runScript)
                """
        case .notInstalled(let missing):
            return """
                \(missing) is missing — Goel° does not look installed on this machine.
                Install it with:
                    curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh
                """
        case .portalUnreachable(let port, let reason):
            return """
                can’t reach the portal on 127.0.0.1:\(port) — \(reason)
                The service may be stopped or still starting. Check `goel status`, then `goel logs`.
                """
        case .usage(let m):
            return m
        }
    }
}

/// Terminal output helpers. Colour is suppressed when stdout is not a terminal and when `NO_COLOR`
/// is set — `goel status` gets piped and grepped, where escape codes break comparisons.
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

    static func error(_ text: String) {
        FileHandle.standardError.write(Data(("goel: " + text + "\n").utf8))
    }

    /// A caution that must survive `>` and `|`: stderr, and never gated on colour — a
    /// warning suppressed when output is redirected fires only when unnecessary.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data((paint("note: ", "33") + text + "\n").utf8))
    }

    /// Key/value block with aligned values, as `goel status` and `goel config` print.
    static func pairs(_ rows: [(String, String)]) {
        let width = rows.map(\.0.count).max() ?? 0
        for (key, value) in rows {
            let padding = String(repeating: " ", count: width - key.count)
            print("  \(dim(key))\(padding)  \(value)")
        }
    }

    /// Left-aligned table with a dim header. Column widths come from the content,
    /// clamped so one absurd filename cannot push the numbers off screen.
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

    // MARK: Formatting

    static func bytes(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = value, index = 0
        while scaled >= 1024, index < units.count - 1 { scaled /= 1024; index += 1 }
        return index == 0 ? "\(Int(scaled)) B"
                          : String(format: "%.1f %@", scaled, units[index])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "—" : bytes(bytesPerSecond) + "/s"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        if total < 86400 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86400)d \((total % 86400) / 3600)h"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }
}
