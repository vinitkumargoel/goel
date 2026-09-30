import Foundation

/// A copied link to a video *page* (not a file) that yt-dlp can turn into a download. The
/// clipboard watcher only offered file links, so a copied YouTube URL — the most common thing
/// people copy to download — never raised the banner. Kept to well-known page shapes: offering
/// every extension-less URL would nag on each link copied from a chat.
enum MediaPageLink {

    static func isLikelyVideoPage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host?.lowercased() else { return false }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        let parts = url.path.split(separator: "/").map { $0.lowercased() }
        let query = url.query?.lowercased() ?? ""
        switch host {
        case "youtube.com":
            return (parts.first == "watch" && query.contains("v="))
                || (parts.count >= 2 && ["shorts", "live", "embed"].contains(parts[0]))
                || (parts.first == "playlist" && query.contains("list="))
        case "youtu.be":
            return parts.count == 1
        case "vimeo.com":
            return parts.last.map { !$0.isEmpty && $0.allSatisfy(\.isNumber) } ?? false
        case "dailymotion.com":
            return parts.count >= 2 && parts[0] == "video"
        case "twitch.tv":
            return parts.count >= 2 && (parts[0] == "videos" || parts[1] == "clip")
        case "x.com", "twitter.com":
            return parts.count >= 3 && parts[1] == "status"
        case "instagram.com":
            return parts.count >= 2 && ["reel", "reels", "p", "tv"].contains(parts[0])
        case "tiktok.com":
            return parts.count >= 3 && parts[1] == "video"
        case "soundcloud.com":
            return parts.count >= 2
        case "bilibili.com":
            return parts.count >= 2 && parts[0] == "video"
        case "reddit.com":
            return parts.count >= 4 && parts[0] == "r" && parts[2] == "comments"
        default:
            return false
        }
    }
}
