import Foundation
import Observation
import OSLog

// MARK: - LinkValidation

/// What the Link field currently holds, judged without touching the network.
///
/// Deliberately a free-standing, nonisolated value type rather than something nested inside
/// ``MetadataProbe``: the Add button's `disabled` state, the inline error message, and the unit
/// tests all need this answer, and none of them should have to own an observable object or hop
/// to the main actor to get it.
///
/// The scheme rule is a product decision, not an implementation detail. `docs/PRD-iOS.md` §4.1
/// asks the app to be honest *before* the tap, and the desktop facade rejects `file://` outright;
/// accepting it here so the transfer could fail later would be exactly the dishonesty the PRD
/// argues against.
public enum LinkValidation: Equatable, Sendable {

    /// Nothing typed yet. Not an error — the sheet shows no message, Add is simply disabled.
    case empty

    /// A parseable `http`/`https` URL with a host.
    case valid(URL)

    /// Unusable, with a complete sentence explaining why. Safe to put straight into a `Text`.
    case invalid(String)

    /// The only two schemes this app can actually transfer.
    public static let supportedSchemes: Set<String> = ["http", "https"]

    /// Pure. No I/O, no actor, no side effects.
    public static func check(_ raw: String) -> LinkValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        guard let url = URL(string: trimmed) else {
            return .invalid(TransferError.invalidURL.userMessage)
        }

        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .invalid("Add http:// or https:// to the front of the link.")
        }

        guard supportedSchemes.contains(scheme) else {
            // Reuses the seam's own sentence so the sheet and the engine never disagree about
            // how an unsupported scheme is described.
            return .invalid(TransferError.unsupportedScheme(scheme).userMessage)
        }

        guard let host = url.host(), !host.isEmpty else {
            return .invalid(TransferError.invalidURL.userMessage)
        }

        return .valid(url)
    }

    public var url: URL? {
        if case let .valid(url) = self { return url }
        return nil
    }

    public var message: String? {
        if case let .invalid(message) = self { return message }
        return nil
    }

    /// Whether Add may be enabled.
    public var isUsable: Bool { url != nil }
}

// MARK: - ProbeState

/// The four things the add sheet can know about a link.
///
/// Free-standing for the same reason as ``LinkValidation``: the timeout race below produces one
/// of these from a nonisolated task group, so the type must not carry main-actor isolation.
public enum ProbeState: Equatable, Sendable {
    case idle
    case probing
    case success(ProbeResult)
    /// A complete, user-facing sentence. Never an error code.
    case failed(String)

    public var result: ProbeResult? {
        if case let .success(result) = self { return result }
        return nil
    }

    public var isProbing: Bool { self == .probing }

    public var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

// MARK: - MetadataProbe

/// Resolves a link's metadata *before* the user commits to it — the whole thesis of the add
/// sheet (`docs/PRD-iOS.md` §4.1: name, exact size, type and resumability known before the tap,
/// "so we say so honestly up front rather than failing at 99 %").
///
/// Three behaviours matter and are easy to lose in a refactor:
///
/// 1. **Debounced.** A probe per keystroke would issue a dozen HEADs while someone pastes and
///    edits a URL. One probe fires ``debounce`` after typing stops.
/// 2. **Cancelled on change.** The in-flight probe for the old URL is cancelled the moment the
///    URL changes, so a slow answer for a stale link can never overwrite a fresh one.
/// 3. **Never blocking.** A timeout or a refusal is not a failure of the sheet. The size row
///    falls back to `Unknown`, the type row to `Unknown`, and Add stays enabled. A server that
///    will not answer a HEAD is a perfectly ordinary server.
@MainActor
@Observable
public final class MetadataProbe {

    /// The pinned spelling used by the sheet: `probe.state`.
    public typealias State = ProbeState

    // MARK: - State

    public private(set) var state: State = .idle

    // `nonisolated` because the timeout race below reads them from a task group, off the main
    // actor. All three are immutable `Sendable` values, so there is nothing to protect.

    /// How long typing must stop before a probe goes out.
    public nonisolated static let debounce: Duration = .milliseconds(400)

    /// Ceiling on one probe. Past this the sheet stops waiting and says so, rather than
    /// spinning forever on a host that accepted the connection and then went quiet.
    public nonisolated static let timeout: Duration = .seconds(5)

    public nonisolated static let timeoutMessage =
        "The server did not answer in time, so the size is unknown until the download starts."

    @ObservationIgnored private let engine: any TransferEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The URL the current task belongs to. Guards against a late answer landing on a new link.
    @ObservationIgnored private var inFlight: URL?

    @ObservationIgnored private static let log = Logger(
        subsystem: GoelIdentifiers.logSubsystem,
        category: "MetadataProbe"
    )

    // MARK: - Life cycle

    public init(engine: any TransferEngine) {
        self.engine = engine
    }

    deinit {
        // A dropped probe must not leave a five-second timer holding a network call alive.
        task?.cancel()
    }

    // MARK: - Driving

    /// Call on every change of the Link field. Cheap, idempotent, and safe to call per keystroke.
    public func update(for raw: String) {
        let validation = LinkValidation.check(raw)

        guard let url = validation.url else {
            // Nothing to ask a server about. Not `.failed` — an empty or half-typed field is
            // not an error the user needs a sentence about.
            cancel()
            state = .idle
            return
        }

        // Same link, already answered or answering. Re-probing on a cursor move is waste.
        guard url != inFlight else { return }

        cancel()
        inFlight = url
        state = .probing

        task = Task { [weak self] in
            try? await Task.sleep(for: MetadataProbe.debounce)
            guard !Task.isCancelled, let self else { return }

            let outcome = await MetadataProbe.resolve(url, using: self.engine)

            // The field moved on while the server was thinking.
            guard !Task.isCancelled, self.inFlight == url else { return }
            if let message = outcome.failureMessage {
                MetadataProbe.log.info("Probe fell back to Unknown: \(message, privacy: .public)")
            }
            self.state = outcome
        }
    }

    /// Drops the in-flight probe and forgets which URL it belonged to.
    public func cancel() {
        task?.cancel()
        task = nil
        inFlight = nil
    }

    /// Back to a blank slate — used when the sheet is reused for a second download.
    public func reset() {
        cancel()
        state = .idle
    }

    // MARK: - The timeout race

    /// Runs the engine probe against a wall clock and returns whichever finishes first.
    ///
    /// `nonisolated` on purpose: this does no UI work, so it must not occupy the main actor for
    /// up to five seconds.
    private nonisolated static func resolve(_ url: URL, using engine: any TransferEngine) async -> ProbeState {
        await withTaskGroup(of: ProbeState.self) { group in
            group.addTask {
                do {
                    return .success(try await engine.probe(url))
                } catch let error as TransferError {
                    return .failed(error.userMessage)
                } catch {
                    return .failed(TransferError.network(error.localizedDescription).userMessage)
                }
            }
            group.addTask {
                try? await Task.sleep(for: MetadataProbe.timeout)
                return .failed(MetadataProbe.timeoutMessage)
            }

            let first = await group.next() ?? .failed(MetadataProbe.timeoutMessage)
            // Whichever lost is now pointless. The sleeping task returns immediately on cancel.
            group.cancelAll()
            return first
        }
    }
}
