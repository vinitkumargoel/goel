import Foundation

// Linux compatibility shims for GoelCore: swift-corelibs-foundation splits pieces of `Foundation`
// into separate modules. Compiled ONLY on Linux / where a module is missing, so macOS is unaffected.

// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on Linux, XMLParser in
// FoundationXML. Re-exported so the rest of the module sees them with only `import Foundation`.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
#if canImport(FoundationXML)
@_exported import FoundationXML
#endif

// Glibc types these C constants differently from Darwin: net/if.h flags import as `Int`, SOCK_* as
// the `__socket_type` enum. Normalising to Int32 once keeps the call sites platform-free.
enum PlatformSocket {
    #if os(Linux)
    static let stream = Int32(SOCK_STREAM.rawValue)
    #else
    static let stream = SOCK_STREAM
    #endif
}

enum InterfaceFlag {
    static let up = Int32(IFF_UP)
    static let running = Int32(IFF_RUNNING)
    static let loopback = Int32(IFF_LOOPBACK)
}

#if os(Linux)

/// Minimal stand-in for `UniformTypeIdentifiers.UTType`: maps a response MIME type to a file extension.
/// Unknown types return nil, so the HTTP engine keeps the URL-derived name exactly as it does on macOS.
struct UTType {
    private let ext: String?

    init?(mimeType: String) {
        let map: [String: String] = [
            "video/mp4": "mp4", "video/webm": "webm", "video/x-matroska": "mkv",
            "video/quicktime": "mov", "video/mpeg": "mpg", "video/x-msvideo": "avi",
            "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/ogg": "ogg",
            "audio/flac": "flac", "audio/wav": "wav",
            "application/zip": "zip", "application/pdf": "pdf", "application/gzip": "gz",
            "application/x-tar": "tar", "application/x-7z-compressed": "7z",
            "application/x-rar-compressed": "rar", "application/vnd.rar": "rar",
            "application/x-iso9660-image": "iso", "application/x-bittorrent": "torrent",
            "application/x-apple-diskimage": "dmg", "application/x-debian-package": "deb",
            "application/vnd.debian.binary-package": "deb", "application/x-msdownload": "exe",
            "application/json": "json", "application/xml": "xml", "text/plain": "txt",
            "text/html": "html", "text/csv": "csv",
            "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif",
            "image/webp": "webp", "image/svg+xml": "svg",
        ]
        self.ext = map[mimeType.lowercased()]
    }

    var preferredFilenameExtension: String? { ext }
}

#endif
