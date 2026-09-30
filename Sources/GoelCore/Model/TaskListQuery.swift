import Foundation

public enum TaskListQuery: Sendable {

    public enum Filter: Sendable, Equatable {
        case all
        case active
        case paused
        case completed
        case seeding
    }

    public enum SortKey: Sendable, Equatable {
        case index
        case name
        case size
        case status
        case added
        case downloadSpeed
        case uploadSpeed
    }

    public static func matches(_ task: DownloadTask, filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .active: return task.status.isActive
        case .paused: return task.status == .paused
        case .completed: return task.status == .completed
        case .seeding: return task.status == .seeding
        }
    }

    public static func statusOrder(_ s: DownloadStatus) -> Int {
        switch s {
        case .downloading: return 0
        case .verifying: return 0
        case .requestingMetadata: return 1
        case .seeding: return 2
        case .queued: return 3
        case .paused: return 4
        case .failed: return 5
        case .completed: return 6
        }
    }

    public static func compare(
        _ a: DownloadTask,
        _ b: DownloadTask,
        key: SortKey,
        ascending: Bool
    ) -> Bool {
        let result: Bool
        switch key {
        case .index:
            // "#" is the queue order the scheduler starts rows in, not when they were added.
            result = QueueOrder.precedes(a, b)
        case .added:
            result = a.addedAt < b.addedAt
        case .name:
            result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case .size:
            result = (a.totalBytes ?? 0) < (b.totalBytes ?? 0)
        case .status:
            result = statusOrder(a.status) < statusOrder(b.status)
        case .downloadSpeed:
            result = a.downloadSpeed < b.downloadSpeed
        case .uploadSpeed:
            result = a.uploadSpeed < b.uploadSpeed
        }
        return ascending ? result : !result
    }

    public static func visible(
        tasks: [DownloadTask],
        filter: Filter,
        search: String,
        sortKey: SortKey,
        ascending: Bool,
        extraMatch: ((DownloadTask) -> Bool)? = nil
    ) -> [DownloadTask] {
        var list = tasks.filter { matches($0, filter: filter) && (extraMatch?($0) ?? true) }
        let query = Search(search)
        if !query.isEmpty {
            list = list.filter(query.matches)
        }
        return list.sorted { compare($0, $1, key: sortKey, ascending: ascending) }
    }

    /// The search field's text, parsed. `host:example` tokens narrow to a source host (every one
    /// must match); whatever else is typed is matched as one phrase against the name, tags, label,
    /// note, source host and source URL, so a pasted link finds its row.
    public struct Search: Sendable, Equatable {
        public let hosts: [String]
        public let text: String

        public init(_ raw: String) {
            var hosts: [String] = []
            var words: [Substring] = []
            var tookToken = false
            for word in raw.split(whereSeparator: \.isWhitespace) {
                let lower = word.lowercased()
                guard lower.hasPrefix("host:") else { words.append(word); continue }
                tookToken = true
                let host = lower.dropFirst("host:".count)
                // A bare "host:" while still typing narrows nothing rather than everything.
                if !host.isEmpty { hosts.append(String(host)) }
            }
            self.hosts = hosts
            // Rebuilt from the words only when a token was taken out, so a plain search keeps
            // its exact inner spacing.
            let phrase = tookToken ? words.joined(separator: " ") : raw.trimmingCharacters(in: .whitespaces)
            self.text = phrase.lowercased()
        }

        public var isEmpty: Bool { hosts.isEmpty && text.isEmpty }

        public func matches(_ task: DownloadTask) -> Bool {
            if !hosts.isEmpty {
                guard let host = task.sourceHost,
                      hosts.allSatisfy({ host.contains($0) }) else { return false }
            }
            guard !text.isEmpty else { return true }
            let q = text
            return task.name.lowercased().contains(q)
                || task.allTags.contains { $0.lowercased().contains(q) }
                || (task.label?.lowercased().contains(q) ?? false)
                || (task.note?.lowercased().contains(q) ?? false)
                || (task.sourceHost?.contains(q) ?? false)
                || task.source.locator.lowercased().contains(q)
        }
    }

    public static func count(tasks: [DownloadTask], filter: Filter) -> Int {
        tasks.filter { matches($0, filter: filter) }.count
    }
}
