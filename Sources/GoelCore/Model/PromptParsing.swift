import Foundation

public enum PromptParsing {

    public static func batchRename(template: String, over names: [String]) -> [String] {
        names.enumerated().map { index, name in
            var candidate = template.replacingOccurrences(of: "#", with: String(index + 1))
            if (candidate as NSString).pathExtension.isEmpty {
                let ext = (name as NSString).pathExtension
                if !ext.isEmpty { candidate += ".\(ext)" }
            }
            return candidate
        }
    }

    public static func requestHeaders(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return headers
    }

    public static func tags(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
