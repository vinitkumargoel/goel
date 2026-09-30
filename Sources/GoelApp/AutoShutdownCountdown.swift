import Foundation
import GoelCore

/// "When downloads finish: Sleep / Shut Down / Quit" waits a minute with Cancel and "Do it now"
/// before acting — the last download finishing must not power off a Mac someone is using.
@MainActor
final class AutoShutdownCountdown: ObservableObject {

    enum Phase: Equatable {
        case idle
        case counting(DrainIntent, remaining: Int)
    }

    static let defaultSeconds = 60

    @Published private(set) var phase: Phase = .idle

    private let seconds: Int
    private let autoTick: Bool
    private let perform: @MainActor (DrainIntent) -> Void
    private var ticker: Task<Void, Never>?

    init(seconds: Int = 60, autoTick: Bool = true,
         perform: @escaping @MainActor (DrainIntent) -> Void) {
        self.seconds = max(1, seconds)
        self.autoTick = autoTick
        self.perform = perform
    }

    var isCounting: Bool { phase != .idle }

    func begin(_ intent: DrainIntent) {
        // A second trigger while counting keeps the first deadline; it must not restart the clock.
        guard phase == .idle else { return }
        phase = .counting(intent, remaining: seconds)
        guard autoTick else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// One second passed. At zero the action runs exactly once.
    func tick() {
        guard case .counting(let intent, let remaining) = phase else { return }
        if remaining <= 1 {
            fire(intent)
        } else {
            phase = .counting(intent, remaining: remaining - 1)
        }
    }

    func cancel() {
        ticker?.cancel()
        ticker = nil
        phase = .idle
    }

    func performNow() {
        guard case .counting(let intent, _) = phase else { return }
        fire(intent)
    }

    private func fire(_ intent: DrainIntent) {
        cancel()
        perform(intent)
    }

    static func title(for intent: DrainIntent) -> String {
        switch intent {
        case .quit: return L10n.t("Downloads finished — Goel° will quit")
        case .sleep: return L10n.t("Downloads finished — this Mac will go to sleep")
        case .shutdown: return L10n.t("Downloads finished — this Mac will shut down")
        }
    }

    static func message(remaining: Int) -> String {
        remaining == 1 ? L10n.t("In 1 second.") : L10n.t("In %d seconds.", remaining)
    }

    static func actionTitle(for intent: DrainIntent) -> String {
        switch intent {
        case .quit: return L10n.t("Quit Now")
        case .sleep: return L10n.t("Sleep Now")
        case .shutdown: return L10n.t("Shut Down Now")
        }
    }
}
