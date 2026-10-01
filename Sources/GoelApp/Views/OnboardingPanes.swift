import SwiftUI
import AppKit
import SafariServices
import GoelCore

/// The first onboarding question. The answer only tailors the steps shown; nothing is locked in.
enum OnboardingBrowserChoice: String, CaseIterable, Identifiable {
    case chrome, safari, firefox, edge, brave, arc, other

    static let storageKey = "onboarding.browser"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .other: return L10n.t("Other")
        }
    }

    /// Safari ships inside the app; everything Chromium or Gecko needs the helper + unpacked extension.
    var needsHelper: Bool { self != .safari && self != .other }

    var loadHint: String {
        switch self {
        case .firefox:
            return L10n.t("about:debugging → This Firefox → Load Temporary Add-on → the folder’s manifest.json.")
        case .safari, .other:
            return ""
        default:
            return L10n.t("Open the extensions page → Developer mode → Load unpacked → the folder.")
        }
    }
}

struct OnboardingBrowserPane: View {
    @AppStorage(OnboardingBrowserChoice.storageKey) private var choiceRaw = ""
    @State private var helperResult: String?
    /// Inline, not a toast: a toast draws in the main window, underneath this sheet.
    @State private var folderMessage: String?

    private var choice: OnboardingBrowserChoice? { OnboardingBrowserChoice(rawValue: choiceRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingBlurb(L10n.t("Goel° catches downloads from your browser — with the page’s sign-in cookies, so files behind a login still work."))
            picker
            if let choice {
                steps(for: choice)
            }
        }
    }

    private var picker: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingBrowserChoice.allCases) { option in
                Button { choiceRaw = option.rawValue } label: {
                    Text(option.title)
                        .scaledFont(size: Theme.TextSize.meta, weight: choice == option ? .semibold : .regular)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(choice == option ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Which browser do you use?"))
    }

    @ViewBuilder
    private func steps(for choice: OnboardingBrowserChoice) -> some View {
        switch choice {
        case .safari:
            OnboardingRow(symbol: "safari", title: L10n.t("Turn on “Goel° Capture” in Safari"),
                          detail: L10n.t("Safari finds the extension inside this app. Enable it and allow it on the sites you use.")) {
                Button(L10n.t("Open Safari Extensions")) {
                    SFSafariApplication.showPreferencesForExtension(
                        withIdentifier: BrowserStatusCards.safariExtensionID) { _ in }
                }
            }
        case .other:
            OnboardingBlurb(L10n.t("No extension needed: drag links onto the Drop Basket (⌘⇧B), copy them with clipboard watching on, or use the bookmarklet in Settings ▸ Browser."))
        default:
            helperRows(choice)
        }
    }

    @ViewBuilder
    private func helperRows(_ choice: OnboardingBrowserChoice) -> some View {
        OnboardingRow(symbol: "app.connected.to.app.below.fill",
                      title: L10n.t("1. Install the messaging helper"),
                      detail: helperResult ?? L10n.t("Lets the extension talk to Goel°. Writes files in your own Library — no admin password.")) {
            Button(L10n.t("Install")) { helperResult = BrowserIntegrationService.installHostManifests() }
                .accessibilityLabel(L10n.t("Install the browser messaging helper"))
        }
        OnboardingRow(symbol: "puzzlepiece.extension",
                      title: L10n.t("2. Load the extension in %@", choice.title),
                      detail: folderMessage ?? choice.loadHint) {
            Button(L10n.t("Show Folder")) { revealFolder() }
                .accessibilityLabel(L10n.t("Show the browser extension folder in Finder"))
        }
        OnboardingBlurb(L10n.t("Then quit and reopen %@ once so it reads the helper.", choice.title))
    }

    private func revealFolder() {
        guard let folder = BrowserIntegrationService.extensionFolder else {
            folderMessage = L10n.t("The bundled extension is only in the packaged app, not a dev build")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// The last step: everything that makes the first download go smoothly, each with its fix.
struct OnboardingReadyPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var notifications: NotificationService.Permission?

    private var ytDlpFound: Bool { YtDlpResolver.isAvailable }

    private var ffmpegFound: Bool {
        if case .found = FFmpegService.resolve(override: vm.settings.ffmpegPath) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingBlurb(L10n.t("A quick look at what Goel° can use on this Mac."))
            notificationRow
            ReadyCheckRow(ok: ytDlpFound, title: L10n.t("yt-dlp"),
                          detail: ytDlpFound ? L10n.t("Found — video pages can be downloaded.")
                                             : L10n.t("Not found — install it (brew install yt-dlp) to save videos from web pages."))
            ReadyCheckRow(ok: ffmpegFound, title: L10n.t("ffmpeg"),
                          detail: ffmpegFound ? L10n.t("Ready — used to merge and convert media.")
                                              : L10n.t("Missing — merging video and audio won’t work."))
            OnboardingRow(symbol: "menubar.rectangle", title: L10n.t("Menu-bar icon"),
                          detail: L10n.t("Speeds and quick controls from the menu bar.")) {
                SettingSwitch(isOn: setting(vm, \.menuBarExtraEnabled))
            }
        }
        .task { notifications = await NotificationService.permission() }
    }

    @ViewBuilder
    private var notificationRow: some View {
        let ok = notifications == .allowed
        ReadyCheckRow(ok: ok, title: L10n.t("Notifications"),
                      detail: ok ? L10n.t("Allowed — you’ll hear when downloads finish or fail.")
                                 : L10n.t("Not allowed yet — Goel° can’t tell you when a download finishes.")) {
            if notifications == .notAsked {
                Button(L10n.t("Allow")) {
                    NotificationService.requestAuthorization()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        notifications = await NotificationService.permission()
                    }
                }
            } else if notifications == .denied {
                Button(L10n.t("Open Settings")) { NotificationService.openSystemSettings() }
            }
        }
    }
}

private struct ReadyCheckRow<Control: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        OnboardingRow(symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                      title: title, detail: detail) {
            control
        }
        .foregroundStyle(ok ? Color.primary : Theme.orange)
    }
}

extension ReadyCheckRow where Control == EmptyView {
    init(ok: Bool, title: String, detail: String) {
        self.init(ok: ok, title: title, detail: detail) { EmptyView() }
    }
}
