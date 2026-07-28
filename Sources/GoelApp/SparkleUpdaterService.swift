import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterService {

    static let shared = SparkleUpdaterService()

    private var controller: SPUStandardUpdaterController?

    /// HTTPS is mandatory: signatures stop payload swaps, but a plaintext feed can pin users to an old release.
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

    /// Presence only — Sparkle itself rejects a malformed EdDSA key; do not add a second parser here.
    var publicEDKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Feed *and* key, both or neither — never run the updater without signature checking.
    var isConfigured: Bool {
        feedURL != nil && publicEDKey != nil
    }

    func startIfConfigured() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    func checkForUpdates() -> Bool {
        guard let controller else { return false }
        controller.checkForUpdates(nil)
        return true
    }
}
