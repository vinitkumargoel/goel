import Foundation

// MARK: - Per-download network selection

/// How ONE download uses the machine's interfaces, overriding ``AppSettings/aggregationEnabled``.
/// One string grammar for JSON / `/api/add` / `--net`: `auto`, `single:wlp13s0`, `aggregate[:a,b]`.
public enum NetworkSelection: Sendable, Equatable, Hashable {
    case auto
    case single(String)
    case aggregate([String])

    /// Interface names go to `SO_BINDTODEVICE` / `IP_BOUND_IF` as C strings, so validate here, not
    /// at the syscall: `IFNAMSIZ` is 16 including the terminator, and only these chars appear.
    public static func isValidInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 15 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Parse the wire/CLI form; nil for anything malformed so callers report rather than silently
    /// falling back to `auto` — "I asked for one interface and got all of them" is worth refusing.
    public init?(spec raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.caseInsensitiveCompare("auto") == .orderedSame {
            self = .auto
            return
        }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let verb = parts[0].lowercased()
        let argument = parts.count > 1 ? String(parts[1]) : ""

        switch verb {
        case "single":
            let name = argument.trimmingCharacters(in: .whitespaces)
            guard Self.isValidInterfaceName(name) else { return nil }
            self = .single(name)
        case "aggregate":
            guard !argument.isEmpty else {
                self = .aggregate([])
                return
            }
            let names = argument.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !names.isEmpty, names.allSatisfy(Self.isValidInterfaceName) else { return nil }
            // One interface named under `aggregate` is a pin, not a fan-out. Normalising
            // here means the engine never has to special-case a one-element "spread".
            self = names.count == 1 ? .single(names[0]) : .aggregate(names)
        default:
            return nil
        }
    }

    /// Round-trips through ``init(spec:)``.
    public var spec: String {
        switch self {
        case .auto: return "auto"
        case .single(let name): return "single:\(name)"
        case .aggregate(let names):
            return names.isEmpty ? "aggregate" : "aggregate:\(names.joined(separator: ","))"
        }
    }

    /// What to show a human.
    public var summary: String {
        switch self {
        case .auto: return "Automatic (server default)"
        case .single(let name): return "Pinned to \(name)"
        case .aggregate(let names):
            return names.isEmpty ? "Split across all eligible interfaces"
                                 : "Split across \(names.joined(separator: ", "))"
        }
    }
}

// MARK: - Resolving a selection against what actually exists

extension AggregationPolicy {

    public struct NetworkResolution: Sendable, Equatable {
        /// Interfaces to bind. Empty means "do not bind" — the OS routing table decides.
        public var adapters: [BoundAdapter]
        /// Set when the request could not be honoured verbatim. Surfaced to the user;
        /// a cable pulled between queueing and starting must not fail the download.
        public var note: String?

        public init(adapters: [BoundAdapter], note: String? = nil) {
            self.adapters = adapters
            self.note = note
        }
    }

    /// Turn a per-download `selection` into bind targets: nil/`.auto` defers to `defaultAdapters`
    /// (what the server-wide policy would use); `available` is every currently bindable interface.
    public static func bindTargets(
        for selection: NetworkSelection?,
        defaultAdapters: [BoundAdapter],
        available: [BoundAdapter]
    ) -> NetworkResolution {
        switch selection ?? .auto {
        case .auto:
            return NetworkResolution(adapters: defaultAdapters)

        case .single(let name):
            guard let match = available.first(where: { $0.bsdName == name }) else {
                return NetworkResolution(
                    adapters: defaultAdapters,
                    note: "\(name) is not available — using the default route instead.")
            }
            return NetworkResolution(adapters: [match])

        case .aggregate(let names):
            let chosen = names.isEmpty
                ? available
                : names.compactMap { name in available.first { $0.bsdName == name } }
            let missing = names.filter { name in !chosen.contains { $0.bsdName == name } }

            if chosen.isEmpty {
                let detail = missing.isEmpty ? "no interfaces are eligible"
                                             : "\(missing.joined(separator: ", ")) unavailable"
                return NetworkResolution(
                    adapters: defaultAdapters,
                    note: "Cannot split this download — \(detail). Using the default route.")
            }
            if chosen.count == 1 {
                let detail = missing.isEmpty
                    ? "only \(chosen[0].label) is eligible"
                    : "\(missing.joined(separator: ", ")) unavailable"
                return NetworkResolution(
                    adapters: chosen,
                    note: "Running on one interface — \(detail).")
            }
            return NetworkResolution(
                adapters: chosen,
                note: missing.isEmpty ? nil
                    : "Skipping \(missing.joined(separator: ", ")) — not available.")
        }
    }
}

extension NetworkSelection: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = NetworkSelection(spec: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "not a network selection: \(raw)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(spec)
    }
}
