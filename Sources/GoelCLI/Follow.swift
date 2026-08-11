import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Written by the SIGINT handler, which may only touch async-signal-safe calls —
/// so the bytes are prepared up front and emitted with write(2).
private let detachNotice = Array("""

goel: detached — the download continues on the daemon; `goel list` to watch it.

""".utf8)

extension GoelCLI {

    /// Mirrors the schemes `DownloadSource.parse` accepts server-side. Anything else
    /// (a path, a bare word) falls through to normal command dispatch.
    static func looksLikeSource(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("magnet:") { return true }
        for scheme in ["http://", "https://", "ftp://", "ftps://", "sftp://"]
            where lower.hasPrefix(scheme) { return true }
        return false
    }

    /// The same URL twice in one `add` (or two dedup-equivalent sources) makes the
    /// portal echo the SAME task ID twice — one download, two ids. Collapse before
    /// reporting, or the caller sees two "Saved" lines / JSON entries for one file.
    static func orderedUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Follows queued tasks until every one reaches a terminal state.
    /// Exit: 0 all completed · 3 any failed/refused · 4 timeout (they keep downloading).
    static func follow(ids: [String], client: API, json: Bool,
                       timeout: Int?, anyRefused: Bool) throws -> Never {
        signal(SIGINT) { _ in
            detachNotice.withUnsafeBufferPointer { _ = write(2, $0.baseAddress, $0.count) }
            _exit(ExitCode.detached)
        }

        let ids = orderedUnique(ids)
        let wanted = Set(ids)
        let tty = isatty(STDOUT_FILENO) == 1
        let interval: TimeInterval = tty ? 0.5 : 2.0
        let deadline = timeout.map { Date().addingTimeInterval(TimeInterval($0)) }
        let progress = ProgressLine(enabled: tty)
        var consecutiveFailures = 0
        var failures: [String: String] = [:]   // id → reason, once terminal

        while true {
            let rows: [API.TaskRow]
            do {
                rows = try client.tasks()
                consecutiveFailures = 0
            } catch {
                // One blip (daemon restarting, socket hiccup) must not abandon a wait;
                // a portal that stays gone for ~10 polls has genuinely died.
                consecutiveFailures += 1
                guard consecutiveFailures < 10 else {
                    progress.clear()
                    throw error
                }
                Thread.sleep(forTimeInterval: interval)
                continue
            }

            let mine = rows.filter { wanted.contains($0.id) }
            var unfinished: [API.TaskRow] = []
            for id in wanted where failures[id] == nil {
                guard let row = mine.first(where: { $0.id == id }) else {
                    failures[id] = "removed from the queue while goel was waiting"
                    continue
                }
                switch row.statusToken {
                case "completed", "seeding":
                    break   // terminal, and good — seeding means the payload is on disk
                case "failed":
                    failures[id] = row.error ?? "failed"
                default:
                    unfinished.append(row)
                }
            }
            let done = wanted.count - unfinished.count

            if unfinished.isEmpty {
                progress.clear()
                try finishFollow(ids: ids, client: client, json: json,
                                 failures: failures, anyRefused: anyRefused)
            }
            if let deadline, Date() >= deadline {
                progress.clear()
                Out.error("still downloading after \(timeout ?? 0)s — detaching; "
                          + "the download continues. `goel list` to watch it.")
                if json { emitDetails(ids: ids, client: client, failures: failures) }
                exit(ExitCode.timedOut)
            }

            progress.render(unfinished, doneCount: done, totalCount: wanted.count)
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private static func finishFollow(ids: [String], client: API, json: Bool,
                                     failures: [String: String], anyRefused: Bool) throws -> Never {
        if json {
            emitDetails(ids: ids, client: client, failures: failures)
        } else {
            for id in ids {
                if let reason = failures[id] {
                    let name = (try? client.taskDetail(id: id))?.row.name ?? String(id.prefix(8))
                    Out.line(Out.red("Failed") + " \(Out.safe(name)) — \(Out.safe(reason))")
                    continue
                }
                guard let detail = try? client.taskDetail(id: id) else {
                    Out.line(Out.green("Done") + " \(id.prefix(8)) — finished, but the detail "
                             + "couldn’t be fetched; `goel list --all` has it.")
                    continue
                }
                // `savePath` is already the full destination (directory + name).
                Out.line(Out.green("Saved") + " \(Out.safe(detail.savePath))")
            }
        }
        exit(failures.isEmpty && !anyRefused ? ExitCode.ok : ExitCode.downloadFailed)
    }

    /// `--json` always answers with an array — one detail object per followed task,
    /// in the order they were queued — so callers never branch on the shape.
    private static func emitDetails(ids: [String], client: API, failures: [String: String]) {
        var parts: [Data] = []
        for id in ids {
            if let detail = try? client.taskDetailRaw(id: id) {
                parts.append(detail)
            } else {
                // A removed task predictably 404s here — the reason follow() recorded is
                // the accurate one, and it must reach the machine-readable output too.
                let stub: [String: String] = ["id": id,
                                              "error": failures[id] ?? "detail unavailable"]
                parts.append((try? JSONSerialization.data(withJSONObject: stub))
                             ?? Data("{\"id\":\"\(id)\",\"error\":\"detail unavailable\"}".utf8))
            }
        }
        var body = Data("[".utf8)
        for (index, part) in parts.enumerated() {
            if index > 0 { body.append(Data(",".utf8)) }
            body.append(part)
        }
        body.append(Data("]".utf8))
        Out.data(body)
    }

    /// One live line, rewritten in place; silent when stdout is not a terminal.
    final class ProgressLine {
        private let enabled: Bool
        private var lastWidth = 0

        init(enabled: Bool) { self.enabled = enabled }

        func render(_ unfinished: [API.TaskRow], doneCount: Int, totalCount: Int) {
            guard enabled else { return }
            let text: String
            if totalCount == 1, let row = unfinished.first {
                text = Self.line(for: row)
            } else {
                let speed = unfinished.reduce(0.0) { $0 + $1.downSpeed }
                let fraction = unfinished.reduce(0.0) { $0 + $1.progress }
                let overall = (Double(doneCount) + fraction) / Double(max(1, totalCount))
                text = "\(doneCount)/\(totalCount) done · \(Out.percent(overall))"
                     + " · \(Out.rate(speed))"
            }
            let padding = String(repeating: " ", count: max(0, lastWidth - text.count))
            print("\r\(text)\(padding)", terminator: "")
            fflush(stdout)
            lastWidth = text.count
        }

        static func line(for row: API.TaskRow) -> String {
            let safeName = Out.safe(row.name)
            let name = safeName.count > 40 ? String(safeName.prefix(39)) + "…" : safeName
            var parts = [name, Out.percent(row.progress)]
            // Metadata-stage torrents and probing HTTP tasks have no speed yet; keep the line honest.
            if row.downSpeed > 0 { parts.append(Out.rate(row.downSpeed)) }
            if let eta = row.etaSeconds { parts.append("ETA " + Out.duration(eta)) }
            parts.append(row.status.lowercased())
            return parts.joined(separator: "  ·  ")
        }

        func clear() {
            guard enabled, lastWidth > 0 else { return }
            print("\r" + String(repeating: " ", count: lastWidth) + "\r", terminator: "")
            fflush(stdout)
            lastWidth = 0
        }
    }
}
