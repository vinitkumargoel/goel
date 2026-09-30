import Foundation

extension FileType {

    /// Checked in this order, first match wins. The original four look for the extension anywhere
    /// in the name, so "release.iso.zip" stays a disc image and "clip.mp4.part" a video. The newer
    /// ones must end the name (or a dotted segment): ".png" inside "a.pngx" is not an image.
    private static let rules: [(type: FileType, pattern: String)] = [
        (.iso, #"\.iso"#),
        (.video, #"\.(mkv|mp4|avi|mov|webm|m4v|wmv|flv|mpe?g)"#),
        (.audio, #"\.(mp3|m4a|m4b|aac|flac|wav|ogg|oga|opus|wma|aiff?|alac|ape)(?![a-z0-9])"#),
        (.image, #"\.(jpe?g|png|gif|heic|heif|webp|tiff?|bmp|svg|avif|psd|raw|cr2|nef|dng)(?![a-z0-9])"#),
        (.archive, #"\.(zip|gz|tar|7z|rar|dmg|bz2|xz)"#),
        (.app, #"\.(app|xip|pkg|exe|deb|msi)"#),
        (.doc, #"\.(pdf|txt|md|rtf|docx?|xlsx?|pptx?|odt|ods|odp|pages|numbers|key|epub|mobi|csv|json|xml|html?)(?![a-z0-9])"#),
    ]

    /// The sidebar's Type groups and the row's icon tile, from the file name alone.
    /// A torrent with no recognisable extension is almost always a video release, so it is filed there.
    static func classify(fileName: String, isTorrent: Bool) -> FileType {
        let lower = fileName.lowercased()
        for rule in rules where lower.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.type
        }
        return isTorrent ? .video : .other
    }
}
