import SwiftUI
import AppKit
import SafariServices
import GoelCore

// MARK: - Browser

/// The browser question. The answer only tailors the steps shown; nothing is locked in.
struct OnboardingBrowserPane: View {
    @AppStorage(OnboardingBrowserChoice.storageKey) private var choiceRaw = ""
    @State private var helperResult: String?
    /// Inline, not a toast: a toast draws in the main window, underneath this sheet.
    @State private var folderMessage: String?
    /// Previews and snapshots show a choice without writing it to the defaults.
    @State private var shownChoice: OnboardingBrowserChoice?

    init(previewChoice: OnboardingBrowserChoice? = nil) {
        _shownChoice = State(initialValue: previewChoice)
    }

    private var choice: OnboardingBrowserChoice? { shownChoice ?? OnboardingBrowserChoice(rawValue: choiceRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.ml) {
            OnboardingBlurb(L10n.t("Goel° catches downloads from your browser — with the page’s "
                + "sign-in cookies, so files behind a login still work."))
            picker
            if let choice {
                steps(for: choice)
            }
        }
    }

    private var picker: some View {
        WindowsFlowLayout(spacing: Studio.Space.xs, lineSpacing: Studio.Space.s) {
            ForEach(OnboardingBrowserChoice.allCases) { option in
                Button {
                    shownChoice = nil
                    choiceRaw = option.rawValue
                } label: {
                    Text(option.title).frame(minWidth: 52)
                }
                .buttonStyle(StudioPillButtonStyle(isOn: choice == option))
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
            OnboardingItem(symbol: "safari", title: L10n.t("Turn on “Goel° Capture” in Safari"),
                           detail: L10n.t("Safari finds the extension inside this app. "
                               + "Enable it and allow it on the sites you use.")) {
                Button(L10n.t("Open Safari Extensions")) {
                    SFSafariApplication.showPreferencesForExtension(
                        withIdentifier: BrowserStatusCards.safariExtensionID) { _ in }
                }
                .buttonStyle(.studio(.primary, size: .small))
            }
        case .other:
            StudioNote(tone: .accent, symbol: "basket",
                       message: L10n.t("No extension needed: drag links onto the Drop Basket (⇧⌘B), copy them "
                           + "with clipboard watching on, or use the bookmarklet in Settings ▸ Browser."))
        default:
            helperRows(choice)
        }
    }

    @ViewBuilder
    private func helperRows(_ choice: OnboardingBrowserChoice) -> some View {
        OnboardingItem(symbol: "app.connected.to.app.below.fill",
                       title: L10n.t("1. Install the messaging helper"),
                       detail: helperResult ?? L10n.t("Lets the extension talk to Goel°. Writes files "
                           + "in your own Library — no admin password.")) {
            Button(L10n.t("Install")) { helperResult = BrowserIntegrationService.installHostManifests() }
                .buttonStyle(.studio(.primary, size: .small))
                .accessibilityLabel(L10n.t("Install the browser messaging helper"))
        }
        OnboardingItem(symbol: "puzzlepiece.extension",
                       title: L10n.t("2. Load the extension in %@", choice.title),
                       detail: folderMessage ?? choice.loadHint,
                       detailTone: folderMessage == nil ? .neutral : .warn) {
            Button(L10n.t("Show Folder")) { revealFolder() }
                .buttonStyle(.studio(.secondary, size: .small))
                .accessibilityLabel(L10n.t("Show the browser extension folder in Finder"))
        }
        Text(L10n.t("Then quit and reopen %@ once so it reads the helper.", choice.title))
            .studioFont(.small)
            .foregroundStyle(Studio.Palette.ink2)
    }

    private func revealFolder() {
        guard let folder = BrowserIntegrationService.extensionFolder else {
            folderMessage = L10n.t("The bundled extension is only in the packaged app, not a dev build")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

// MARK: - Ready check

/// The last step: everything that makes the first download go smoothly, each with its fix.
struct OnboardingReadyPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var notifications: NotificationService.Permission?
    private let probesNotifications: Bool

    /// `knownPermission` skips asking the system (previews and snapshots).
    init(knownPermission: NotificationService.Permission? = nil) {
        _notifications = State(initialValue: knownPermission)
        probesNotifications = knownPermission == nil
    }

    private var ytDlpFound: Bool { YtDlpResolver.isAvailable }

    private var ffmpegFound: Bool {
        if case .found = FFmpegService.resolve(override: vm.settings.ffmpegPath) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            OnboardingBlurb(L10n.t("A quick look at what Goel° can use on this Mac."))
                .padding(.bottom, Studio.Space.xxs)
            check(ok: ytDlpFound, symbol: "film", title: L10n.t("yt-dlp"),
                  detail: ytDlpFound ? L10n.t("Found — video pages can be downloaded.")
                                     : L10n.t("Not found — install it (brew install "
                                         + "yt-dlp) to save videos from web pages."))
            check(ok: ffmpegFound, symbol: "arrow.left.arrow.right", title: L10n.t("ffmpeg"),
                  detail: ffmpegFound ? L10n.t("Ready — used to merge and convert media.")
                                      : L10n.t("Missing — merging video and audio won’t work."))
            OnboardingItem(title: L10n.t("Menu-bar icon"),
                           detail: L10n.t("Speeds and quick controls from the menu bar."),
                           leading: { WindowsGlyphTile(symbol: "menubar.rectangle") }) {
                Toggle(isOn: onboardingSetting(vm, \.menuBarExtraEnabled)) { EmptyView() }
                    .toggleStyle(.studioSwitch)
                    .accessibilityLabel(L10n.t("Menu-bar icon"))
            }
            notificationRow
        }
        .task {
            guard probesNotifications else { return }
            notifications = await NotificationService.permission()
        }
    }

    private func check(ok: Bool, symbol: String, title: String, detail: String) -> some View {
        OnboardingItem(title: title, detail: detail, detailTone: ok ? .neutral : .warn,
                       leading: { WindowsGlyphTile(symbol: symbol, tone: ok ? .accent : .warn) }) {
            StudioPill(ok ? L10n.t("Ready") : L10n.t("Missing"), tone: ok ? .good : .warn)
        }
    }

    @ViewBuilder
    private var notificationRow: some View {
        let ok = notifications == .allowed
        OnboardingItem(title: L10n.t("Notifications"),
                       detail: ok ? L10n.t("Allowed — you’ll hear when downloads finish or fail.")
                                  : L10n.t("Not allowed yet — Goel° can’t tell you when a download finishes."),
                       detailTone: ok || notifications == nil ? .neutral : .warn,
                       leading: {
                           WindowsGlyphTile(symbol: "bell", tone: ok || notifications == nil ? .accent : .warn)
                       }) {
            switch notifications {
            case .allowed:
                StudioPill(L10n.t("On"), tone: .good)
            case .notAsked:
                Button(L10n.t("Allow")) {
                    NotificationService.requestAuthorization()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        notifications = await NotificationService.permission()
                    }
                }
                .buttonStyle(.studio(.primary, size: .small))
            case .denied:
                Button(L10n.t("Open Settings")) { NotificationService.openSystemSettings() }
                    .buttonStyle(.studio(.secondary, size: .small))
            case nil:
                ProgressView().controlSize(.small)
            }
        }
    }
}
