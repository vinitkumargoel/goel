import Foundation

/// What a pasted server address or an `~/.ssh/config` Host entry fills into the SFTP editor.
struct SFTPAddress: Equatable {
    var host: String
    var port: Int?
    var username: String?
    var path: String?
    /// The ssh-config alias, used as the connection's name.
    var alias: String?
    var identityFile: String?

    init(host: String, port: Int? = nil, username: String? = nil, path: String? = nil,
         alias: String? = nil, identityFile: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.path = path
        self.alias = alias
        self.identityFile = identityFile
    }

    /// `sftp://user@host:2222/path`, `ssh://…`, `scp://…`, scp-style `user@host:path`, or a bare `host[:port]`.
    /// A password in the URL is dropped on purpose: it belongs in the password field (Keychain).
    static func parse(_ raw: String) -> SFTPAddress? {
        parseUnchecked(raw).flatMap { $0.isSafe ? $0 : nil }
    }

    /// A host or user starting with "-" would read as an option to `ssh`/`sftp` (e.g. the
    /// "Open in Terminal" command), so it is never accepted, whatever the source.
    var isSafe: Bool {
        !host.hasPrefix("-") && !(username?.hasPrefix("-") ?? false)
    }

    private static func parseUnchecked(_ raw: String) -> SFTPAddress? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard ["sftp", "ssh", "scp"].contains(scheme),
                  let c = URLComponents(string: text), let host = c.host, !host.isEmpty else { return nil }
            let path = c.path.isEmpty ? nil : c.percentEncodedPath.removingPercentEncoding ?? c.path
            return SFTPAddress(host: host, port: c.port, username: c.user.flatMap { $0.isEmpty ? nil : $0 },
                               path: path)
        }
        var rest = Substring(text)
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
            if user?.isEmpty == true { return nil }
        }
        var port: Int?
        var path: String?
        if rest.hasPrefix("[") {           // [ipv6]:port
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") { port = Int(tail.dropFirst()) }
            return host.isEmpty ? nil : SFTPAddress(host: host, port: port, username: user)
        }
        if let colon = rest.firstIndex(of: ":") {
            let after = String(rest[rest.index(after: colon)...])
            if let n = Int(after), (1...65535).contains(n) {
                port = n
            } else if !after.isEmpty {
                path = after                    // scp style host:path
            }
            rest = rest[..<colon]
        }
        let host = String(rest)
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else { return nil }
        return SFTPAddress(host: host, port: port, username: user, path: path)
    }
}

/// The subset of `ssh_config(5)` the editor can use: concrete `Host` aliases and their
/// HostName / User / Port / IdentityFile. Wildcard hosts and `Match` blocks are skipped.
enum SSHConfigImport {

    static var defaultPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config") }

    static func load(path: String = defaultPath) -> [SFTPAddress] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [SFTPAddress] {
        var out: [SFTPAddress] = []
        var current: [SFTPAddress] = []
        var inMatch = false

        func flush() { out.append(contentsOf: current); current = [] }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let (key, value) = keyValue(line) else { continue }
            switch key {
            case "host":
                flush()
                inMatch = false
                current = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    .map { SFTPAddress(host: $0, alias: $0) }
            case "match":
                flush()
                inMatch = true
            default:
                guard !inMatch, !current.isEmpty else { continue }
                for i in current.indices { apply(key, value, to: &current[i]) }
            }
        }
        flush()
        var seen: Set<String> = []
        return out.filter { $0.isSafe && seen.insert($0.alias ?? $0.host).inserted }
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        let separators = CharacterSet(charactersIn: " \t=")
        guard let r = line.rangeOfCharacter(from: separators) else { return nil }
        let key = line[..<r.lowerBound].lowercased()
        let value = line[r.upperBound...].trimmingCharacters(in: separators.union(.whitespaces))
        return value.isEmpty ? nil : (key, value)
    }

    /// ssh keeps the FIRST value it sees for each key, so later lines never override.
    private static func apply(_ key: String, _ value: String, to entry: inout SFTPAddress) {
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        switch key {
        case "hostname" where entry.host == entry.alias:
            entry.host = unquoted
        case "user" where entry.username == nil:
            entry.username = unquoted
        case "port" where entry.port == nil:
            entry.port = Int(unquoted).flatMap { (1...65535).contains($0) ? $0 : nil }
        case "identityfile" where entry.identityFile == nil:
            entry.identityFile = (unquoted as NSString).expandingTildeInPath
        default:
            break
        }
    }
}
