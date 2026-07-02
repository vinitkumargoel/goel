import Foundation

// ============================================================================
// Linux compatibility shims for GoelCore.
//
// swift-corelibs-foundation splits a few things out of `Foundation` into
// separate modules, and Linux lacks a handful of macOS-only frameworks. These
// shims are compiled ONLY on Linux (or only where a module is missing), so the
// macOS build is completely unaffected.
// ============================================================================

// URLSession / URLRequest / HTTPURLResponse live in FoundationNetworking on
// Linux; XMLParser lives in FoundationXML. Re-export them so the rest of the
// module sees these types with only `import Foundation`.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
#if canImport(FoundationXML)
@_exported import FoundationXML
#endif

#if os(Linux)

/// Minimal stand-in for `UniformTypeIdentifiers.UTType`, covering the one use in
/// the HTTP engine: mapping a response MIME type to a preferred file extension.
/// Only the common web-download types are needed; anything unknown returns nil
/// (the engine then simply keeps the URL-derived name, exactly as on macOS when
/// the type is unrecognized).
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
