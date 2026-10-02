import Foundation
import GoelCore

/// What narrows the list: a status, a file type and a tag, each independent and ANDed together,
/// so "Active · Audio · Work" is one view. The rail, the header chips, the palette and the ⌘1…⌘9
/// shortcuts all write through ``setting(_:)``, which changes one axis and leaves the others.
/// Not persisted: every launch opens on All downloads.
struct DownloadFilters: Hashable {
    /// One of the status entries (`.all`, `.active`, `.queued`, `.paused`, `.completed`,
    /// `.seeding`, `.failed`); never `.type` or `.tag`.
    var status: SidebarFilter = .all
    var type: FileType?
    /// Compared case-insensitively, like ``ListPresentation/matches(_:filter:)``.
    var tag: String?

    var isEmpty: Bool { status == .all && type == nil && tag == nil }

    /// `filter` applied to its own axis; `.all` clears the status axis only.
    func setting(_ filter: SidebarFilter) -> DownloadFilters {
        var next = self
        switch filter {
        case .type(let type): next.type = type
        case .tag(let tag): next.tag = tag
        default: next.status = filter
        }
        return next
    }

    /// Whether `filter`'s axis currently holds `filter`. `.all` is on while no status is picked.
    func isOn(_ filter: SidebarFilter) -> Bool {
        switch filter {
        case .type(let type): return self.type == type
        case .tag(let name): return tag?.caseInsensitiveCompare(name) == .orderedSame
        default: return status == filter
        }
    }

    /// The single filter this narrows to, for callers that predate the axes: tag, else type,
    /// else status.
    var primary: SidebarFilter {
        if let tag { return .tag(tag) }
        if let type { return .type(type) }
        return status
    }

    /// The axes in use, status first, as single filters.
    var active: [SidebarFilter] {
        var parts: [SidebarFilter] = []
        if status != .all { parts.append(status) }
        if let type { parts.append(.type(type)) }
        if let tag { parts.append(.tag(tag)) }
        return parts
    }

    /// "Active · Audio · Work", or "All downloads" with nothing picked.
    var title: String {
        let parts = active
        return parts.isEmpty ? SidebarFilter.all.accessibilityName
                             : parts.map(\.accessibilityName).joined(separator: " · ")
    }

    func matches(_ task: DownloadTask) -> Bool {
        active.allSatisfy { ListPresentation.matches(task, filter: $0) }
    }

    /// A renamed tag stays the filter under its new name.
    func renamingTag(_ old: String, to new: String) -> DownloadFilters {
        guard let tag, tag.caseInsensitiveCompare(old) == .orderedSame else { return self }
        var next = self
        next.tag = new
        return next
    }

    /// A tag removed from every row can't filter anything; the other axes stay.
    func removingTag(_ old: String) -> DownloadFilters {
        guard let tag, tag.caseInsensitiveCompare(old) == .orderedSame else { return self }
        var next = self
        next.tag = nil
        return next
    }
}
