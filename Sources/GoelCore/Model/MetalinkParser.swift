import Foundation

public struct MetalinkFile: Sendable, Equatable {
    public var name: String
    public var urls: [String]
    public var size: Int64?
    public var checksum: Checksum?
}

/// RFC 5854 and Metalink 3. Only http(s) URLs are kept — every other scheme is dropped.
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
        private var hashType: String?
        private var currentURLSortKey: Int = .max
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
                // Normalised to smaller-sorts-first: RFC 5854 `priority` is low-is-better, v3 `preference` isn't.
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
                    // `sorted(by:)` isn't stable — the offset tiebreaker preserves document order.
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
