import Foundation
import Sparkle

/// Sparkle auto-updates for packaged builds. Both the appcast URL and the EdDSA key are read from
/// the bundle and validated first — a half-configured bundle gets no updater rather than a crash.
@MainActor
final class SparkleUpdaterService {

    static let shared = SparkleUpdaterService()

    private var controller: SPUStandardUpdaterController?

    /// The appcast URL this build was packaged with, or nil when unusable. HTTPS is required: the
    /// signature stops payload substitution, but a plaintext feed can still pin users to an old release.
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

    /// The base64 EdDSA public key this build was packaged with, or nil when absent. Only presence
    /// is checked — Sparkle rejects a malformed key itself, and duplicating its parser is not our job.
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
