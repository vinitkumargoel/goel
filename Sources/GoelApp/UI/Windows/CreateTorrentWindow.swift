import SwiftUI
import AppKit
import GoelCore

/// File ▸ Create Torrent…: its own window, so hashing a large folder never blocks the list.
@MainActor
final class CreateTorrentWindow {
    static let shared = CreateTorrentWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let vm = AppViewModel.shared else { return }
        let host = NSHostingController(rootView: CreateTorrentView(onClose: { [weak self] in self?.close() })
            .environmentObject(vm))
        let window = NSWindow(contentViewController: host)
        window.title = L10n.t("Create Torrent")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // The sheet draws its own heading; the title bar blends into it.
        window.applyStudioChrome()
        window.titleVisibility = .hidden
        window.backgroundColor = Studio.Tones.sheet.nsColor
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

extension CreateTorrentView {
    /// Read by the hashing thread; a class so the flag outlives the view's value copies.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }
}

extension AppViewModel {
    /// Seeds a torrent just made from local data: saved beside the source, so libtorrent finds
    /// every piece already complete and goes straight to seeding.
    func seedCreatedTorrent(_ torrent: URL, sourcePath: String) {
        let folder = (sourcePath as NSString).deletingLastPathComponent
        let manager = self.manager
        Task { await manager.add(source: .torrentFile(torrent), saveDirectory: folder) }
    }
}

/// What the source card says about the chosen file or folder: "Folder · 24 files · 1.3 GB".
struct TorrentSourceSummary: Equatable, Sendable {
    var isFolder: Bool
    var fileCount: Int
    var totalBytes: Int64

    /// Walks the folder off the main thread; nil when the path can't be read.
    static func load(_ path: String) async -> TorrentSourceSummary? {
        await Task.detached(priority: .utility) { scan(path) }.value
    }

    private static func scan(_ path: String) -> TorrentSourceSummary? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return TorrentSourceSummary(isFolder: false, fileCount: 1, totalBytes: size)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
        else { return nil }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in walker {
            if Task.isCancelled { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return TorrentSourceSummary(isFolder: true, fileCount: count, totalBytes: bytes)
    }

    var text: String {
        guard isFolder else { return L10n.t("File · %@", totalBytes.byteString) }
        return L10n.t("Folder · %1$@ · %2$@",
                      fileCount == 1 ? L10n.t("1 file") : L10n.t("%d files", fileCount), totalBytes.byteString)
    }
}
