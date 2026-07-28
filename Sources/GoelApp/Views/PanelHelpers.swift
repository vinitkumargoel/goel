import AppKit
import UniformTypeIdentifiers

/// Thin wrappers around the `NSOpenPanel`/`NSSavePanel` ritual so call sites state only what
/// differs. Optional prompt/message/types apply only when supplied, so each site keeps its flags.
enum FilePicker {
    /// Pick a single existing directory.
    static func chooseDirectory(prompt: String? = nil, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Pick a single existing file, optionally constrained to `types`.
    static func openFile(types: [UTType]? = nil, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let types { panel.allowedContentTypes = types }
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Pick one or more files and/or directories (multiple selection).
    static func openItems(canChooseFiles: Bool = true, canChooseDirectories: Bool = false,
                          prompt: String? = nil, message: String? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = true
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    /// Pick a save destination, suggesting `name` and constraining to `type`.
    static func save(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// Collect the URLs a drag carries and hand them to `done` on the main queue once every provider
/// loads. `fileURLsOnly` both narrows accepted providers and discards any non-file URL.
func collectDroppedURLs(_ providers: [NSItemProvider], fileURLsOnly: Bool = false,
                        _ done: @escaping ([URL]) -> Void) -> Bool {
    let matching = providers.filter {
        fileURLsOnly ? $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                     : $0.canLoadObject(ofClass: URL.self)
    }
    guard !matching.isEmpty else { return false }
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in matching {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, !fileURLsOnly || url.isFileURL {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls) }
    return true
}
