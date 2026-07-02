import Foundation
import Sparkle

/// Sparkle-based auto-updates for packaged, signed builds.
///
/// Sparkle needs two things this repo deliberately doesn't hardcode: a hosted
/// appcast (`SUFeedURL`) and the EdDSA public key matching the release-signing
/// key (`SUPublicEDKey`). `build_app.sh` stamps both into Info.plist when the
/// `SPARKLE_FEED_URL` / `SPARKLE_ED_KEY` env vars are set at package time.
/// Builds without them (including every dev build) never start Sparkle and
/// fall back to the built-in HTTPS release-feed checker.
@MainActor
final class SparkleUpdaterService {

    static let shared = SparkleUpdaterService()

    private var controller: SPUStandardUpdaterController?

    /// Whether this build carries the appcast + key Sparkle requires.
    var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    /// Start the updater (scheduled background checks per Sparkle defaults).
    /// A no-op unless the build is configured.
    func startIfConfigured() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// Run a user-initiated check with Sparkle's own UI. Returns false when
    /// Sparkle isn't active (caller falls back to the feed checker).
    func checkForUpdates() -> Bool {
        guard let controller else { return false }
        controller.checkForUpdates(nil)
        return true
    }
}
