import SwiftUI
import AppKit
import GoelCore

/// Plain `UserDefaults`, never ``AppSettings``: a backup import must not be able to replay first run.
enum OnboardingState {

    /// Bumping this re-shows the whole flow to every existing user.
    static let currentVersion = 1

    private static let completedVersionKey = "onboarding.completedVersion"
    private static let licenceNoticeDismissedKey = "onboarding.licenceNoticeDismissed"

    static var needsOnboarding: Bool {
        UserDefaults.standard.integer(forKey: completedVersionKey) < currentVersion
    }

    static func markCompleted() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
    }

    static var licenceNoticeDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: licenceNoticeDismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: licenceNoticeDismissedKey) }
    }

    static let commercialURL = URL(string: "https://goel.vinitk.dev/commercial")!
}

struct OnboardingView: View {

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Pane: Int, CaseIterable {
        case saveFolder, browser, clipboard

        var title: String {
            switch self {
            case .saveFolder: return L10n.t("Where should downloads land?")
            case .browser:    return L10n.t("Catch downloads from your browser")
            case .clipboard:  return L10n.t("Copy a link, download it")
            }
        }

        var symbol: String {
            switch self {
            case .saveFolder: return "folder"
            case .browser:    return "safari"
            case .clipboard:  return "doc.on.clipboard"
            }
        }
    }

    @State private var pane: Pane = .saveFolder

    @State private var helperResult: String?

    @State private var licenceNoticeVisible = !OnboardingState.licenceNoticeDismissed

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch pane {
                    case .saveFolder: saveFolderPane
                    case .browser:    browserPane
                    case .clipboard:  clipboardPane
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(height: 300)

            Divider()
            footer
        }
        .frame(width: 580)
        // The catch-all exit path: ⎋ and the window close button do not call finish().
        .onDisappear { OnboardingState.markCompleted() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: pane.symbol)
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Welcome to Goel°"))
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.t("Welcome to Goel"))
                Text(pane.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
        }
        .padding(18)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if pane == .clipboard, licenceNoticeVisible {
                licenceNotice
            }
            HStack(spacing: 8) {
                progressDots
                Spacer()
                if pane == .saveFolder {
                    Button(L10n.t("Skip")) { finish() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(L10n.t("Skip setup"))
                } else {
                    Button(L10n.t("Back")) { pane = Pane(rawValue: pane.rawValue - 1) ?? .saveFolder }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(L10n.t("Back to the previous step"))
                }
                Button(pane == .clipboard ? L10n.t("Start using Goel°") : L10n.t("Continue")) {
                    if let next = Pane(rawValue: pane.rawValue + 1) {
                        pane = next
                    } else {
                        finish()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(Pane.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step.rawValue <= pane.rawValue ? Theme.accent : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .a11yGroup(label: L10n.t("Setup progress"),
                   value: L10n.t("Step %1$@ of %2$@", String(pane.rawValue + 1), String(Pane.allCases.count)))
    }

    private var licenceNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .a11yDecorative()
            noticeText
                .scaledFont(size: 11)
                .accessibilityLabel(L10n.t("Free for personal use. Commercial use requires a licence. Learn more."))
                .accessibilityAddTraits(.isLink)
            Spacer(minLength: 8)
            Button {
                licenceNoticeVisible = false
                OnboardingState.licenceNoticeDismissed = true
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help(L10n.t("Hide this notice"))
            .a11yButton(L10n.t("Hide licence notice"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline))
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(OnboardingState.commercialURL) }
    }

    private var noticeText: Text {
        Text(L10n.t("Free for personal use. Commercial use requires a licence — "))
            .foregroundStyle(.secondary)
        + Text(L10n.t("Learn more"))
            .foregroundStyle(Theme.accent)
    }

    private var saveFolderPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingBlurb(
                L10n.t("Everything you queue lands in one place unless you say otherwise. "
                + "You can still pick a different folder for any individual download."))

            OnboardingCard {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                        .a11yDecorative()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentFolderLabel)
                            .scaledFont(size: 13, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(vm.settings.defaultFolderRule == "fixed"
                             ? L10n.t("Every download goes here.")
                             : L10n.t("Sorted automatically by file type."))
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(L10n.t("Choose…")) { chooseFolder() }
                        .accessibilityLabel(L10n.t("Choose download folder"))
                }
            }

            OnboardingRow(symbol: "wand.and.stars",
                          title: L10n.t("Or let Goel° sort them"),
                          detail: L10n.t("Video, archives, disc images and documents each get their own subfolder.")) {
                Button(vm.settings.defaultFolderRule == "byType" ? L10n.t("Chosen") : L10n.t("Sort by type")) {
                    vm.update { $0.defaultFolderRule = "byType" }
                }
                .disabled(vm.settings.defaultFolderRule == "byType")
                .accessibilityLabel(vm.settings.defaultFolderRule == "byType"
                                    ? L10n.t("Sorting by file type, already chosen")
                                    : L10n.t("Sort downloads by file type"))
            }
        }
    }

    private var currentFolderLabel: String {
        switch vm.settings.defaultFolderRule {
        case "byType":   return L10n.t("Automatic — by file type")
        case "bySource": return L10n.t("Automatic — by source site")
        default:
            return (vm.settings.defaultSaveDirectory as NSString).abbreviatingWithTildeInPath
        }
    }

    private func chooseFolder() {
        guard let url = FilePicker.chooseDirectory(
            prompt: L10n.t("Use Folder"),
            message: L10n.t("Choose where Goel° saves finished downloads.")) else { return }
        vm.setDefaultSaveDirectory(url.path)
        vm.update { $0.defaultFolderRule = "fixed" }
    }

    private var browserPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingBlurb(
                L10n.t("With the extension installed, clicking a download in Chrome, Edge, Brave, "
                + "Firefox or Safari sends it here instead — with the page's sign-in cookies, "
                + "so files behind a login still work."))

            OnboardingRow(symbol: "puzzlepiece.extension",
                          title: L10n.t("1. Load the extension"),
                          detail: L10n.t("Opens the folder to point your browser's “Load unpacked” at.")) {
                Button(L10n.t("Show Folder")) { revealExtensionFolder() }
                    .accessibilityLabel(L10n.t("Show the browser extension folder in Finder"))
            }

            OnboardingRow(symbol: "app.connected.to.app.below.fill",
                          title: L10n.t("2. Install the messaging helper"),
                          detail: helperResult
                              ?? L10n.t("Lets the extension talk to Goel°. Writes files in your own Library — no admin password.")) {
                Button(L10n.t("Install")) { helperResult = BrowserIntegrationService.installHostManifests() }
                    .accessibilityLabel(L10n.t("Install the browser messaging helper"))
            }

            OnboardingBlurb(
                L10n.t("Not now? The full step-by-step, plus the bookmarklet, the URL scheme and the "
                + "Services-menu route, all live in Settings ▸ Browser."))
        }
    }

    private func revealExtensionFolder() {
        guard let folder = BrowserIntegrationService.extensionFolder else {
            vm.toastNow(L10n.t("The bundled extension is only in the packaged app, not a dev build"))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private var clipboardPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingBlurb(
                L10n.t("Goel° can watch for http(s) and magnet links you copy and offer them in a "
                + "banner. It only ever offers — nothing downloads without you clicking Add."))

            OnboardingCard {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                        .a11yDecorative()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("Watch the clipboard"))
                            .scaledFont(size: 13, weight: .medium)
                        Text(L10n.t("Links you copy appear as a one-click banner at the top of the window."))
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    SettingSwitch(isOn: setting(vm, \.clipboardMonitorEnabled))
                }
            }

            Text(L10n.t("A few other ways in"))
                .scaledFont(size: 10.5, weight: .bold)
                .accessibilityAddTraits(.isHeader)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)

            OnboardingRow(symbol: "tray.and.arrow.down",
                          title: L10n.t("Drop Basket · ⌘⇧B"),
                          detail: L10n.t("A small always-on-top target — drag links onto it from anywhere.")) {
                Button(L10n.t("Show")) { DropBasketController.shared.toggle() }
                    .accessibilityLabel(L10n.t("Show drop basket"))
            }
            OnboardingRow(symbol: "link.badge.plus",
                          title: L10n.t("Link Grabber · ⌘⇧L"),
                          detail: L10n.t("Give it a page URL and it lists every file linked from it to pick from.")) {
                EmptyView()
            }
            OnboardingRow(symbol: "command",
                          title: L10n.t("Command palette · ⌘K"),
                          detail: L10n.t("Every action and settings pane in one search field.")) {
                EmptyView()
            }
        }
    }

    private func finish() {
        OnboardingState.markCompleted()
        dismiss()
    }
}

private struct OnboardingBlurb: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .scaledFont(size: 12)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

private struct OnboardingRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(size: 13)
                Text(detail)
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .a11yGroup(label: title, value: detail)
            Spacer(minLength: 8)
            control
        }
    }
}
