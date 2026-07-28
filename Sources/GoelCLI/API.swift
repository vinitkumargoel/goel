import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux
#endif

/// Client for the daemon's own web-portal API — the same JSON routes the portal and extension use.
/// The CLI adds no second control channel, so there is exactly one authorisation path.
struct API {
    let port: Int
    let token: String

    /// Always 127.0.0.1: the CLI runs on the daemon's host and the portal always listens on loopback,
    /// so using the network address would send the token across the wire over plain HTTP.
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
    }

    func tasks() throws -> [TaskRow] {
        try decode([TaskRow].self, from: get("/api/tasks"))
    }

    func add(urls: [String], folder: String?, priority: String?, paused: Bool,
             network: String? = nil) throws -> AddResult {
        var body: [String: Any] = ["url": urls.joined(separator: "\n"), "paused": paused]
        if let folder, !folder.isEmpty { body["folder"] = folder }
        if let priority, !priority.isEmpty { body["priority"] = priority }
        if let network, !network.isEmpty { body["network"] = network }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try decode(AddResult.self, from: post("/api/add", body: data))
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

    /// `POST` routes that take `?id=` and answer `{"ok":true}`.
    func act(_ route: String, id: String? = nil, extra: [String: String] = [:]) throws {
        var query = extra
        if let id { query["id"] = id }
        _ = try post(route + queryString(query), body: nil)
    }

    // MARK: Transport

    private func get(_ path: String) throws -> Data {
        try send(path: path, method: "GET", body: nil)
    }

    private func post(_ path: String, body: Data?) throws -> Data {
        try send(path: path, method: "POST", body: body)
    }

    /// Synchronous by design: this is a one-shot CLI, and a semaphore around a
    /// single request is easier to reason about than an async main.
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
        // The timeout above bounds the request; this bounds the wait even if the
        // session never calls back at all, so the CLI cannot hang forever.
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
            throw CLIError.message("""
                the portal refused this (403). Either read-only mode is on, or the
                folder you asked for is outside the downloads root.
                """)
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
