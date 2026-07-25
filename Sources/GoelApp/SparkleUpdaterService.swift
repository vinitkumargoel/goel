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
///
/// Both values are read from the bundle at runtime and *validated* before the
/// updater is allowed to start. Sparkle itself would throw an unhandled
/// exception at launch on a malformed feed URL, and a build carrying a feed but
/// no key would download updates it cannot verify — so a half-configured bundle
/// is treated exactly like an unconfigured one: no updater, no crash, and the
/// user keeps the manual release-feed check. This is also why the service never
/// falls back to a compiled-in default: an update channel that the packager did
/// not explicitly opt into is a channel nobody audited.
@MainActor
final class SparkleUpdaterService {

    static let shared = SparkleUpdaterService()

    private var controller: SPUStandardUpdaterController?

    /// The appcast URL this build was packaged with, or nil when absent or
    /// unusable. HTTPS is required, not preferred: the appcast decides which
    /// binary the app downloads, and although the EdDSA signature stops a
    /// network attacker substituting a *payload*, a plaintext feed still lets
    /// one pin users to an older signed release with a known hole.
    var feedURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }

    /// The base64 EdDSA public key this build was packaged with, or nil when
    /// absent or blank. Only presence is checked here — Sparkle rejects a
    /// malformed key itself, and this type has no business duplicating its
    /// parser.
    var publicEDKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether this build carries a usable appcast *and* key. Both or neither:
    /// signature checking is not an optional extra.
    var isConfigured: Bool {
        feedURL != nil && publicEDKey != nil
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
