import AppKit
import UniformTypeIdentifiers

enum FilePicker {
    static func chooseDirectory(prompt: String? = nil, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func openFile(types: [UTType]? = nil, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let types { panel.allowedContentTypes = types }
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

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

    static func save(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

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
