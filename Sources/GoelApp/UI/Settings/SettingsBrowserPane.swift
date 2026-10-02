import SwiftUI
import AppKit
import SafariServices
import GoelCore

/// Browser: the live state of each browser, the full per-browser steps, the ways in that need no
/// extension, and the site logins kept in the Keychain.
struct BrowserSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var installResult: String?
    private let cards: BrowserStatusCards
    private let credentialStore: any CredentialManaging

    private static let bookmarklet =
        "javascript:location.href='goeldownloader://add?url='+encodeURIComponent(location.href)"

    init(cards: BrowserStatusCards = BrowserStatusCards(),
         credentialStore: any CredentialManaging = KeychainCredentialStore()) {
        self.cards = cards
        self.credentialStore = credentialStore
    }

    var body: some View {
        SettingsPane(title: L10n.t("Browser"),
                     subtitle: L10n.t("Capture downloads from your browser, or send links here by hand.")) {
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                StudioSectionHeader(L10n.t("Your browsers"))
                    .padding(.horizontal, Studio.Space.xxs)
                cards
            }
            chromiumCard
            safariCard
                .settingsColumn(.trailing)
            withoutExtensionCard
            SiteLoginsCard(store: credentialStore)
                .settingsColumn(.trailing)
            helpCard
                .settingsColumn(.trailing)
        }
    }

    private var chromiumCard: some View {
        SettingsCard(title: L10n.t("Chrome, Edge, Brave & Firefox"), symbol: "globe") {
            SettingRow(L10n.t("1. Install the messaging helper"),
                       detail: installResult ?? L10n.t("Lets the extension talk to this app — nothing works without "
                           + "it. Writes per-browser manifests in your Library; no admin needed. Open a browser at "
                           + "least once first, and click this again if you ever move the app.")) {
                Button(L10n.t("Install Helper")) {
                    installResult = BrowserIntegrationService.installHostManifests()
                }
                .buttonStyle(.studio(.primary, size: .small))
            }
            SettingRow(L10n.t("2. Load the extension"),
                       detail: L10n.t("Chrome/Edge/Brave/Vivaldi/Arc: chrome://extensions → Developer mode → "
                           + "Load unpacked → this folder. Firefox 128+: about:debugging → Load Temporary "
                           + "Add-on → the folder’s manifest.json. A temporary add-on lasts until Firefox "
                           + "quits, so reload it each launch until a signed add-on ships.")) {
                Button(L10n.t("Show Folder"), systemImage: "folder") {
                    if let folder = BrowserIntegrationService.extensionFolder {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } else {
                        vm.settingsMessage(L10n.t("Browser Extension"),
                            L10n.t("The bundled extension folder is only available in the packaged app, not a dev "
                                + "build."))
                    }
                }
                .buttonStyle(.studio(.secondary, size: .small))
            }
            SettingRow(L10n.t("3. Restart the browser"),
                       detail: L10n.t("Browsers read the helper’s manifest only at startup, so quit and reopen the "
                           + "browser fully — otherwise the extension reports that it can’t reach this app. "
                           + "Firefox: do this before loading the add-on in step 2; restarting afterwards unloads it.")) {
                EmptyView()
            }
            SettingRow(L10n.t("4. Capture"),
                       detail: L10n.t("Click the extension’s toolbar button to toggle capture of all downloads, or "
                           + "right-click any link → “Download with Goel°”. For files behind a login, use "
                           + "“(stay signed in)” and accept the cookie prompt.")) {
                EmptyView()
            }
        }
    }

    private var safariCard: some View {
        SettingsCard(title: "Safari", symbol: "safari") {
            SettingRow(L10n.t("1. Open Safari’s extensions"),
                       detail: L10n.t("Safari finds the extension bundled inside this app — no helper and no "
                           + "loading needed. If you just installed the app, quit and reopen Safari once so it "
                           + "appears.")) {
                Button(L10n.t("Open Safari Extensions")) { openSafariExtensionPrefs() }
                    .buttonStyle(.studio(.secondary, size: .small))
            }
            SettingRow(L10n.t("2. Turn it on"),
                       detail: L10n.t("Enable “Goel° Capture” in the list, and allow it on the sites you use. An "
                           + "unsigned (ad-hoc) build also needs Safari → Develop menu → “Allow Unsigned "
                           + "Extensions” each session.")) {
                EmptyView()
            }
            SettingRow(L10n.t("3. Capture"),
                       detail: L10n.t("Click the Goel° toolbar button to turn capture on: clicking a download link, "
                           + "including one that redirects to a file, sends it here instead of Safari. Or "
                           + "right-click a link → “Download with Goel°”, or a video page → “Download video "
                           + "from this page with Goel°”. Links from Safari open here with a quick confirmation.")) {
                EmptyView()
            }
            SettingRow(L10n.t("What Safari can’t do"),
                       detail: L10n.t("Safari has no downloads API, so capture works by catching link clicks: a "
                           + "download a page starts from its own script or a form still goes to Safari. No "
                           + "signed-in downloads either: its sandbox can only reach this app through a URL, which "
                           + "macOS logs, so a session cookie is refused rather than written there. Use Chrome or "
                           + "Firefox for those.")) {
                EmptyView()
            }
        }
    }

    private var withoutExtensionCard: some View {
        SettingsCard(title: L10n.t("Without the extension"), symbol: "link") {
            SettingRow(L10n.t("URL scheme"),
                       detail: L10n.t("goeldownloader://add?url=… opens and queues the link (packaged app).")) {
                Button(L10n.t("Copy Example"), systemImage: "doc.on.doc") {
                    vm.copyToPasteboard("goeldownloader://add?url=https%3A%2F%2Fexample.com%2Ffile.zip")
                }
                .buttonStyle(.studio(.secondary, size: .small))
            }
            SettingRow(L10n.t("Bookmarklet"),
                       detail: L10n.t("Drag-save as a bookmark; clicking it sends the current page here.")) {
                Button(L10n.t("Copy Bookmarklet"), systemImage: "doc.on.doc") {
                    vm.copyToPasteboard(Self.bookmarklet)
                }
                .buttonStyle(.studio(.secondary, size: .small))
            }
            SettingRow(L10n.t("Services menu"),
                       detail: L10n.t("Select a link in any app → right-click → Services → "
                           + "“Download with Goel°”.")) {
                EmptyView()
            }
            SettingRow(L10n.t("Drop basket"),
                       detail: L10n.t("A small always-on-top target for dragging links out of the browser "
                           + "(⌘⇧B).")) {
                Button(L10n.t("Show")) { DropBasketController.shared.toggle() }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .accessibilityLabel(L10n.t("Show drop basket"))
            }
        }
    }

    private static let guideURL = "https://github.com/vinitkumargoel/goel/blob/main/docs/browser-extension.md"

    private var helpCard: some View {
        SettingsCard(title: L10n.t("Help"), symbol: "questionmark.circle") {
            SettingRow(L10n.t("Full instructions"),
                       detail: L10n.t("Per-browser steps, what each browser supports, and fixes for the common "
                           + "failures.")) {
                Button(L10n.t("Open Guide"), systemImage: "arrow.up.right.square") {
                    if let url = URL(string: Self.guideURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.studio(.secondary, size: .small))
            }
        }
    }

    private func openSafariExtensionPrefs() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: BrowserStatusCards.safariExtensionID) { error in
            guard error != nil else { return }
            Task { @MainActor in
                vm.settingsMessage(L10n.t("Safari Extension"),
                    L10n.t("Couldn’t open Safari’s extension settings. Open Safari ▸ Settings ▸ Extensions "
                        + "manually — the extension only registers from the installed app."))
            }
        }
    }
}

/// Site logins kept in the Keychain and sent as HTTP Basic auth to matching hosts.
struct SiteLoginsCard: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var entries: [HostCredential] = []
    @State private var newHost = ""
    @State private var newUser = ""
    @State private var newPassword = ""

    let store: any CredentialManaging

    var body: some View {
        SettingsCard(title: L10n.t("Site logins"), symbol: "key",
                     footer: L10n.t("Stored in your Keychain. Sent as HTTP Basic auth when a download matches the "
                         + "host.")) {
            ForEach(entries) { entry in
                SettingRow(entry.host, detail: L10n.t("User: %@", entry.username)) {
                    SettingsRowIconButton(symbol: "trash", label: L10n.t("Remove saved login for %@", entry.host),
                                          help: L10n.t("Remove login")) { confirmRemove(entry) }
                }
            }
            SettingRow(L10n.t("Host"), detail: L10n.t("e.g. files.example.com")) {
                SettingsTextField(text: $newHost, width: 180, placeholder: L10n.t("files.example.com"), isMonospaced: true)
            }
            SettingRow(L10n.t("Username")) {
                SettingsTextField(text: $newUser, width: 180, placeholder: L10n.t("Required"))
            }
            SettingRow(L10n.t("Password")) {
                SettingsSecureField(text: $newPassword, width: 180, placeholder: L10n.t("Optional"),
                                    accessibilityName: L10n.t("Password for the new site login"))
            }
            SettingsActionRow {
                Button(L10n.t("Add Login"), systemImage: "plus") { addLogin() }
                    .buttonStyle(.studio(.primary, size: .small))
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty || newUser.isEmpty)
            }
        }
        .onAppear(perform: refresh)
    }

    private func confirmRemove(_ entry: HostCredential) {
        vm.settingsConfirm(
            title: L10n.t("Remove the saved login for %@?", entry.host),
            message: L10n.t("The stored username and password are deleted from your Keychain."),
            confirmTitle: L10n.t("Remove"),
            destructive: true
        ) {
            guard store.removeCredential(host: entry.host) else {
                vm.toastNow(L10n.t("Your Keychain refused to remove the login for %@ — unlock it, allow the prompt, "
                    + "and try again", entry.host),
                            isError: true)
                return
            }
            refresh()
            vm.toastSuccess(L10n.t("Login removed"))
        }
    }

    private func addLogin() {
        let host = newHost.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, !newUser.isEmpty else { return }
        // Fields stay filled on failure: retrying is the only recovery, and retyping a password isn't one.
        guard store.setCredential(username: newUser, password: newPassword, host: host) else {
            vm.toastNow(L10n.t("Your Keychain refused to save the login for %@ — unlock it, allow the prompt, and "
                + "try again", host),
                        isError: true)
            return
        }
        newHost = ""; newUser = ""; newPassword = ""
        refresh()
    }

    private func refresh() {
        entries = store.allCredentials()
    }
}
