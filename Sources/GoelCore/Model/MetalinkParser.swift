import Foundation

/// One downloadable file described by a metalink document: a name, the mirror
/// list, and (when published) the size and an integrity hash — everything the
/// add pipeline needs to create a mirrored, checksum-verified task.
public struct MetalinkFile: Sendable, Equatable {
    public var name: String
    /// Every http(s) source, ordered by the document's priority/preference hint
    /// (highest priority first; equal/unhinted mirrors keep document order).
    public var urls: [String]
    public var size: Int64?
    public var checksum: Checksum?
}

/// Parses Metalink documents — RFC 5854 (`.meta4`, `urn:ietf:params:xml:ns:metalink`)
/// and the older Metalink 3 (`.metalink`, `<resources><url type="http">`).
/// Only http(s) URLs are kept: metalink files routinely carry ftp/BitTorrent
/// alternatives this pipeline routes differently or not at all.
public enum MetalinkParser {

    public static func parse(_ data: Data) -> [MetalinkFile] {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.files.filter { !$0.urls.isEmpty }
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var files: [MetalinkFile] = []
        private var current: MetalinkFile?
        private var text = ""
        /// The hash type attribute of the element being read ("sha-256", "md5"…).
        private var hashType: String?
        /// The current `<url>`'s normalised ordering hint — smaller sorts first
        /// (higher priority). Absent hint uses `.max`, sorting the mirror last.
        private var currentURLSortKey: Int = .max
        /// http(s) mirrors collected for the current `<file>`, each with its sort
        /// key; ordered by priority (stable within equal keys) when the file ends.
        private var currentURLEntries: [(url: String, sortKey: Int)] = []

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch name.lowercased() {
            case "file":
                current = MetalinkFile(name: attributes["name"] ?? "", urls: [],
                                       size: nil, checksum: nil)
                currentURLEntries = []
            case "url":
                // v3 carries type="http"/"ftp"; v4 has no type (scheme decides).
                // Normalise the ordering hint to a key where *smaller sorts first*
                // (higher priority): v4 `priority` is already "lower is better"
                // (RFC 5854), while v3 `preference` is "higher is better", so it's
                // negated. An absent hint sorts last.
                if let priority = attributes["priority"].flatMap(Int.init) {
                    currentURLSortKey = priority
                } else if let preference = attributes["preference"].flatMap(Int.init) {
                    currentURLSortKey = -preference
                } else {
                    currentURLSortKey = .max
                }
            case "hash":
                hashType = attributes["type"]?.lowercased()
            default:
                break
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name.lowercased() {
            case "url":
                if current != nil,
                   let url = URL(string: value),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    currentURLEntries.append((url.absoluteString, currentURLSortKey))
                }
            case "size":
                if var file = current, let size = Int64(value), size >= 0 {
                    file.size = size
                    current = file
                }
            case "hash":
                // Prefer the strongest hash the document offers.
                if var file = current, let type = hashType,
                   let algorithm = Self.algorithm(for: type),
                   let parsed = Checksum.parse(value, algorithm: algorithm),
                   Self.rank(algorithm) > (file.checksum.map { Self.rank($0.algorithm) } ?? -1) {
                    file.checksum = parsed
                    current = file
                }
                hashType = nil
            case "file":
                if var file = current {
                    // Order mirrors by their priority/preference hint. The offset
                    // tiebreaker keeps document order among equal-priority (and
                    // hint-less) mirrors, since `sorted(by:)` isn't guaranteed stable.
                    file.urls = currentURLEntries
                        .enumerated()
                        .sorted { ($0.element.sortKey, $0.offset) < ($1.element.sortKey, $1.offset) }
                        .map(\.element.url)
                    files.append(file)
                }
                current = nil
                currentURLEntries = []
            default:
                break
            }
            text = ""
        }

        private static func algorithm(for type: String) -> ChecksumAlgorithm? {
            switch type {
            case "sha-512", "sha512": return .sha512
            case "sha-256", "sha256": return .sha256
            case "sha-1", "sha1": return .sha1
            case "md5": return .md5
            default: return nil
            }
        }

        private static func rank(_ algorithm: ChecksumAlgorithm) -> Int {
            switch algorithm {
            case .md5: return 0
            case .sha1: return 1
            case .sha256: return 2
            case .sha512: return 3
            }
        }
    }
}
