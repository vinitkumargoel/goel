import Foundation
import GoelCore

/// The one place a drag-and-drop becomes downloads. The main window, the Add sheet and the
/// drop basket all route through here, so a dropped `.torrent` from Finder behaves the same
/// wherever it lands — before this, the main window fed `file://` URLs to `add(rawLines:)`,
/// whose parser only accepts http(s)/ftp/sftp/magnet, and failed with "Enter a URL first".
enum InboundDrop {

    /// What a drop contains, sorted by how each part is queued.
    struct Plan: Equatable {
        /// Local `.torrent` files: queued through `ExternalAdd`, the same path as Finder's Open With.
        var torrentFiles: [URL] = []
        /// Anything that is not a local file (http, magnet, ftp…): handed to the link parser.
        var links: [URL] = []
        /// Local files Goel cannot download from (a .zip, a folder, a .txt).
        var unsupportedFiles: [URL] = []

        var isEmpty: Bool { torrentFiles.isEmpty && links.isEmpty && unsupportedFiles.isEmpty }

        /// Newline-joined links, as `add(rawLines:)` and the Add sheet's editor take them.
        var linkLines: String { links.map(\.absoluteString).joined(separator: "\n") }
    }

    static func isTorrentFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "torrent"
    }

    static func plan(for urls: [URL]) -> Plan {
        var plan = Plan()
        for url in urls {
            if isTorrentFile(url) {
                plan.torrentFiles.append(url)
            } else if url.isFileURL {
                plan.unsupportedFiles.append(url)
            } else {
                plan.links.append(url)
            }
        }
        return plan
    }

    /// The toast shown for dropped files that are neither links nor torrents, or nil if there are none.
    static func unsupportedMessage(for files: [URL]) -> String? {
        switch files.count {
        case 0: return nil
        case 1: return L10n.t("Goel takes links and .torrent files — “%@” is neither", files[0].lastPathComponent)
        default: return L10n.t("Goel takes links and .torrent files — %d of the dropped files are neither", files.count)
        }
    }

    /// Queues a whole drop: torrents via `ExternalAdd`, links via `add(rawLines:)`.
    /// A drop is an explicit user action, so nothing here asks for confirmation.
    @MainActor
    static func route(_ urls: [URL], into vm: AppViewModel?,
                      saveDirectory: String? = nil, priority: FilePriority = .normal) {
        let plan = plan(for: urls)
        guard !plan.isEmpty else { return }
        queueTorrentFiles(plan.torrentFiles)
        if !plan.links.isEmpty {
            if let vm {
                vm.add(rawLines: plan.linkLines, saveDirectory: saveDirectory, priority: priority)
            } else {
                ExternalAdd.post(lines: plan.linkLines)
            }
        }
        // Last, so the toast queue ends on the part of the drop that was refused.
        if let message = unsupportedMessage(for: plan.unsupportedFiles) {
            vm?.toastNow(message, isError: true)
        }
    }

    /// `DownloadSource.parse` rejects `file:`, so local torrents go through `ExternalAdd`, exactly
    /// like a `.torrent` opened from Finder.
    @MainActor
    static func queueTorrentFiles(_ urls: [URL]) {
        for url in urls {
            guard var payload = ExternalAdd.payload(from: url) else { continue }
            payload.needsConfirmation = false
            ExternalAdd.post(payload)
        }
    }
}
