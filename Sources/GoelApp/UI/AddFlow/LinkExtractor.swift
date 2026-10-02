import Foundation
import GoelCore

/// The link grabber's logic, moved unchanged out of the old `LinkGrabberSheet` view file:
/// `LinkReview` sorts review rows with the same categories.
struct GrabbedLink: Hashable {
    enum Category: Hashable {
        case archive, video, audio, image, software, document, other
        var label: String {
            switch self {
            case .archive: return L10n.t("Archives")
            case .video: return L10n.t("Video")
            case .audio: return L10n.t("Audio")
            case .image: return L10n.t("Images")
            case .software: return L10n.t("Software")
            case .document: return L10n.t("Documents")
            case .other: return L10n.t("Other")
            }
        }
    }

    var url: String
    var category: Category
    var displayName: String {
        let last = URL(string: url)?.lastPathComponent ?? ""
        return last.isEmpty ? url : last
    }
}

enum LinkExtractor {

    private static let extensionCategories: [(Set<String>, GrabbedLink.Category)] = [
        (["zip", "rar", "7z", "gz", "bz2", "xz", "tar", "tgz"], .archive),
        (["mp4", "mkv", "webm", "avi", "mov", "m4v", "ts", "m3u8"], .video),
        (["mp3", "m4a", "flac", "wav", "ogg", "aac", "opus"], .audio),
        (["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp"], .image),
        (["dmg", "pkg", "exe", "msi", "deb", "rpm", "appimage", "apk", "xip"], .software),
        (["pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv"], .document),
        (["iso", "img", "bin", "torrent"], .other),
    ]

    /// The grabber shows at most this many; ``extractAll(from:baseURL:)`` says how many there were.
    static let displayCap = 500

    static func extract(from html: String, baseURL: URL) -> [GrabbedLink] {
        Array(extractAll(from: html, baseURL: baseURL).prefix(displayCap))
    }

    static func extractAll(from html: String, baseURL: URL) -> [GrabbedLink] {
        var seen = Set<String>()
        var results: [GrabbedLink] = []
        let pattern = #"(?:href|src)\s*=\s*["']([^"'<>\s]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: html) else { return }
            let raw = String(html[r])
            guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") else { return }
            guard let category = category(for: resolved) else { return }
            let absolute = resolved.absoluteString
            guard seen.insert(absolute).inserted else { return }
            results.append(GrabbedLink(url: absolute, category: category))
        }
        return results
    }

    static func category(for url: URL) -> GrabbedLink.Category? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        for (extensions, category) in extensionCategories where extensions.contains(ext) {
            return category
        }
        return nil
    }
}

/// The first web link on the clipboard, for the grabber's page field; nil when there is none.
enum LinkGrabberPrefill {
    /// A pasted essay isn't worth scanning token by token.
    private static let maxScanned = 20_000

    static func pageURL(fromClipboard text: String) -> String? {
        let tokens = text.prefix(maxScanned).split(whereSeparator: { $0.isWhitespace })
        for token in tokens {
            let candidate = String(token)
            guard let url = URL(string: candidate),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else { continue }
            return candidate
        }
        return nil
    }
}
