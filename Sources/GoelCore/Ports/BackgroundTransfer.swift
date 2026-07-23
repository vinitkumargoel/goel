import Foundation

// MARK: - Background-transfer seam (define-only)

/// Whether a transfer engine's network work keeps making progress after the OS has
/// suspended the app.
///
/// - ``foreground``: an in-process `URLSession` that is paused the moment the app is
///   suspended and resumed when it returns to the foreground. This is what the
///   desktop needs and what every engine here does today.
/// - ``background``: an out-of-process, OS-managed `URLSession(background:)` whose
///   transfers continue (and can relaunch the app on completion) while it is
///   suspended. This is what **iOS** requires for a download to finish while the
///   user is in another app.
public enum TransferExecutionMode: String, Sendable {
    case foreground
    case background
}

/// The seam that marks a transfer engine's execution mode, so a future
/// background-capable engine can be introduced without the scheduler having to learn
/// a new type — it keeps depending only on `any DownloadEngine` and can consult this
/// when it needs to reason about suspension behaviour.
///
/// **Define-only, by design (plan Stage 1a/W2).** Every engine today reports
/// ``TransferExecutionMode/foreground``; there is deliberately no `background`
/// conformer yet. A real iOS background engine is a separate, later task — the
/// current segmented, multi-connection HTTP design is *incompatible* with a
/// background `URLSession` (which owns its own single-stream scheduling), so it is a
/// from-scratch implementation rather than a flag flip. Declaring the seam now lets
/// that engine slot in against a stable contract, and lets the two existing engines
/// state their nature in code rather than by omission.
public protocol BackgroundTransferStrategy: Sendable {
    /// The execution mode this engine's transfers run under. Constant per engine.
    var executionMode: TransferExecutionMode { get }
}
