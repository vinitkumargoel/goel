import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux
#endif

struct API {
    let port: Int
    let token: String

    /// Always 127.0.0.1: a network address would send the bearer token across the wire over plain HTTP.
    private var base: String { "http://127.0.0.1:\(port)" }

    struct TaskRow: Decodable {
        let id: String
        let name: String
        let status: String
        let statusToken: String
        let kind: String
        let progress: Double
        let downSpeed: Double
        let totalBytes: Double?
        let doneBytes: Double
        let etaSeconds: Double?
        let error: String?
    }

    struct AddResult: Decodable {
        let added: Int
        let refused: Int
        /// Task IDs for the accepted sources; nil when the daemon predates the field.
        let ids: [String]?
    }

    func tasks() throws -> [TaskRow] {
        try decode([TaskRow].self, from: get("/api/tasks"))
    }

    /// The portal's reply verbatim — `--json` passes this through untouched, so the
    /// CLI never narrows what the API reports.
    func tasksRaw() throws -> Data {
        try get("/api/tasks")
    }

    struct TaskDetailLite: Decodable {
        struct Row: Decodable {
            let name: String
            let statusToken: String
            let error: String?
        }
        let row: Row
        let savePath: String
    }

    func taskDetailRaw(id: String) throws -> Data {
        try get("/api/task?id=\(id)")
    }

    func taskDetail(id: String) throws -> TaskDetailLite {
        try decode(TaskDetailLite.self, from: taskDetailRaw(id: id))
    }

    func add(urls: [String], folder: String?, priority: String?, paused: Bool,
             network: String? = nil) throws -> (AddResult, Data) {
        var body: [String: Any] = ["url": urls.joined(separator: "\n"), "paused": paused]
        if let folder, !folder.isEmpty { body["folder"] = folder }
        if let priority, !priority.isEmpty { body["priority"] = priority }
        if let network, !network.isEmpty { body["network"] = network }
        let data = try JSONSerialization.data(withJSONObject: body)
        let reply = try post("/api/add", body: data)
        return (try decode(AddResult.self, from: reply), reply)
    }

    struct NetworkState: Decodable {
        struct Adapter: Decodable {
            let name: String
            let label: String
            let type: String
            let ipv4: String?
            let expensive: Bool
            let eligible: Bool
        }
        let aggregation: Bool
        let streamsPerAdapter: Int
        let selected: [String]
        let reason: String?
        let locked: Bool
        let adapters: [Adapter]
    }

    func network() throws -> NetworkState {
        try decode(NetworkState.self, from: get("/api/network"))
    }

    func act(_ route: String, id: String? = nil, extra: [String: String] = [:]) throws {
        var query = extra
        if let id { query["id"] = id }
        _ = try post(route + queryString(query), body: nil)
    }

    private func get(_ path: String) throws -> Data {
        try send(path: path, method: "GET", body: nil)
    }

    private func post(_ path: String, body: Data?) throws -> Data {
        try send(path: path, method: "POST", body: body)
    }

    private func send(path: String, method: String, body: Data?) throws -> Data {
        guard let url = URL(string: base + path) else {
            throw CLIError.message("bad request path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        final class Box: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
            var error: Error?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            done.signal()
        }.resume()
        // Bounds the wait even if the session never calls back at all, so the CLI cannot hang forever.
        if done.wait(timeout: .now() + 20) == .timedOut {
            throw CLIError.message("no response from the portal on port \(port) after 20s")
        }
        if let error = box.error {
            throw CLIError.portalUnreachable(port: port, reason: error.localizedDescription)
        }
        guard let http = box.response as? HTTPURLResponse else {
            throw CLIError.portalUnreachable(port: port, reason: "no HTTP response")
        }
        let data = box.data ?? Data()
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw CLIError.message("""
                the portal rejected the API token (401).
                If you changed it by hand, `goel config get token` should match
                \(Layout.tokenFile(databasePath: Layout.defaultDatabase)), and the service
                needs a restart after either changes.
                """)
        case 403:
            // The portal states its reason in the body — SSRF refusal, read-only mode,
            // unwritable folder. Pass it through rather than guessing.
            let reason = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError.forbidden(reason.isEmpty
                ? "the portal refused this (403) — read-only mode, or a folder outside the allowed root."
                : reason)
        default:
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError.message("portal returned HTTP \(http.statusCode)"
                                   + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CLIError.message("couldn’t read the portal's reply: \(error)")
        }
    }

    private func queryString(_ items: [String: String]) -> String {
        guard !items.isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = items.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return "?" + (components.percentEncodedQuery ?? "")
    }
}
