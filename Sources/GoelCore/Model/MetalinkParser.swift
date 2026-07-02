import Foundation

/// One downloadable file described by a metalink document: a name, the mirror
/// list, and (when published) the size and an integrity hash — everything the
/// add pipeline needs to create a mirrored, checksum-verified task.
public struct MetalinkFile: Sendable, Equatable {
    public var name: String
    /// Every http(s) source, in document order (document priority respected).
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
        /// Metalink 3 wraps hashes in `<verification>`; v4 puts `<hash>` on the file.
        private var currentURLPreference: Int?

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch name.lowercased() {
            case "file":
                current = MetalinkFile(name: attributes["name"] ?? "", urls: [],
                                       size: nil, checksum: nil)
            case "url":
                // v3 carries type="http"/"ftp"; v4 has no type (scheme decides).
                currentURLPreference = attributes["preference"].flatMap(Int.init)
                    ?? attributes["priority"].flatMap(Int.init)
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
                if var file = current,
                   let url = URL(string: value),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    file.urls.append(url.absoluteString)
                    current = file
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
                if let file = current { files.append(file) }
                current = nil
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
