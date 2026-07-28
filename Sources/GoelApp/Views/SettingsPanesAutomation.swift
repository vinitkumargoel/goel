import SwiftUI
import AppKit
import SafariServices
import GoelCore

@MainActor
func setting<T>(_ vm: AppViewModel, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { vm.settings[keyPath: keyPath] },
        set: { newValue in vm.update { $0[keyPath: keyPath] = newValue } }
    )
}

struct SchedulerPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        PaneScaffold(title: L10n.t("Scheduler"),
                     subtitle: L10n.t("Download windows, scheduled profiles, and what happens when the queue finishes.")) {
            SectionHeader(L10n.t("When downloads finish"))
            SetRow(name: L10n.t("Then"), desc: L10n.t("One-shot — resets to “Do nothing” after it fires.")) {
                Dropdown(selection: setting(vm, \.autoShutdownAction), items: [
                    .option("none", L10n.t("Do nothing")),
                    .option("quit", L10n.t("Quit Goel°")),
                    .option("sleep", L10n.t("Sleep")),
                    .option("shutdown", L10n.t("Shut down")),
                ], width: 180)
            }

            SectionHeader(L10n.t("Download window"))
            SetRow(name: L10n.t("Only download during a daily window"),
                   desc: L10n.t("Outside the window active downloads pause and queued ones wait.")) {
                SettingSwitch(isOn: setting(vm, \.scheduleEnabled))
            }
            if vm.settings.scheduleEnabled {
                SetRow(name: L10n.t("Start"), desc: "") {
                    Dropdown(selection: setting(vm, \.scheduleStartMinute), items: Self.timeOptions, width: 110)
                }
                SetRow(name: L10n.t("End"), desc: L10n.t("An end before the start wraps past midnight.")) {
                    Dropdown(selection: setting(vm, \.scheduleEndMinute), items: Self.timeOptions, width: 110)
                }
                SetRow(name: L10n.t("Days"), desc: "") {
                    Dropdown(selection: daysBinding, items: [
                        .option("all", L10n.t("Every day")),
                        .option("weekdays", L10n.t("Weekdays")),
                        .option("weekend", L10n.t("Weekends")),
                    ], width: 130)
                }
                SetRow(name: L10n.t("Profile inside the window"),
                       desc: L10n.t("Switch traffic profiles while the window is open (restored after).")) {
                    Dropdown(selection: setting(vm, \.scheduleProfileName),
                             items: [Dropdown<String>.Item.option("", L10n.t("Keep current"))]
                                + vm.settings.profiles.map { .option($0.name, $0.name) },
                             width: 140)
                }
            }
        }
    }

    private static let timeOptions: [Dropdown<Int>.Item] =
        stride(from: 0, to: 1440, by: 60).map { minutes in
            .option(minutes, String(format: "%02d:%02d", minutes / 60, minutes % 60))
        }

    private var daysBinding: Binding<String> {
        Binding(
            get: {
                switch Set(vm.settings.scheduleDays) {
                case Set(2...6): return "weekdays"
                case [1, 7]: return "weekend"
                default: return "all"
                }
            },
            set: { preset in
                vm.update {
                    switch preset {
                    case "weekdays": $0.scheduleDays = [2, 3, 4, 5, 6]
                    case "weekend": $0.scheduleDays = [1, 7]
                    default: $0.scheduleDays = [1, 2, 3, 4, 5, 6, 7]
                    }
                }
            }
        )
    }
}

struct RSSPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var newURL = ""
    @State private var newPattern = ""
    @State private var newStartPaused = false

    var body: some View {
        PaneScaffold(title: L10n.t("RSS Feeds"),
                     subtitle: L10n.t("Watch feeds and queue new items automatically (podcasts, releases, torrent feeds).")) {
            SetRow(name: L10n.t("Check feeds every"), desc: "") {
                Dropdown(selection: setting(vm, \.rssPollIntervalMinutes), items: [
                    .option(15, L10n.t("15 minutes")),
                    .option(30, L10n.t("30 minutes")),
                    .option(60, L10n.t("Hour")),
                    .option(360, L10n.t("6 hours")),
                ], width: 130)
            }

            SectionHeader(L10n.t("Feeds"))
            if vm.settings.rssFeeds.isEmpty {
                Text(L10n.t("No feeds yet — add one below."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(vm.settings.rssFeeds) { feed in
                SetRow(name: feed.url,
                       desc: (feed.titlePattern.isEmpty
                           ? L10n.t("Every item")
                           : L10n.t("Titles containing “%@”", feed.titlePattern))
                           + (feed.startPaused ? L10n.t(" · added paused") : "")) {
                    HStack(spacing: 10) {
                        SettingSwitch(isOn: feedEnabledBinding(feed.id))
                        Button {
                            vm.update { $0.rssFeeds.removeAll { $0.id == feed.id } }
                            vm.toastNow(L10n.t("Feed removed"))
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.t("Remove feed"))
                        .a11yButton(L10n.t("Remove feed %@", feed.url))
                    }
                }
            }

            SectionHeader(L10n.t("Add a feed"))
            SetRow(name: L10n.t("Feed URL"), desc: L10n.t("RSS 2.0 or Atom.")) {
                SettingText(text: $newURL, width: 220)
            }
            SetRow(name: L10n.t("Title contains"), desc: L10n.t("Leave empty to take every item.")) {
                SettingText(text: $newPattern, width: 160)
            }
            SetRow(name: L10n.t("Add items paused"), desc: L10n.t("Review matches before any bytes move.")) {
                SettingSwitch(isOn: $newStartPaused)
            }
            SetRow(name: "", desc: "") {
                Button(L10n.t("Add Feed")) { addFeed() }
                    .disabled(URL(string: newURL.trimmingCharacters(in: .whitespaces))?.host == nil)
            }
        }
    }

    private func feedEnabledBinding(_ id: RSSFeed.ID) -> Binding<Bool> {
        Binding(
            get: { vm.settings.rssFeeds.first { $0.id == id }?.enabled ?? false },
            set: { newValue in
                vm.update {
                    guard let i = $0.rssFeeds.firstIndex(where: { $0.id == id }) else { return }
                    $0.rssFeeds[i].enabled = newValue
                }
            }
        )
    }

    private func addFeed() {
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let feed = RSSFeed(url: url,
                           titlePattern: newPattern.trimmingCharacters(in: .whitespaces),
                           startPaused: newStartPaused)
        vm.update { $0.rssFeeds.append(feed) }
        newURL = ""
        newPattern = ""
        newStartPaused = false
        vm.toastNow(L10n.t("Feed added"))
    }
}

struct RemoteAccessPane: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Never bind the plaintext to settings — only the hash computed on "Set" is persisted.
    @State private var newPassword = ""

    private static let managedKeys: [ManagedPolicy.Key] = [
        .remoteAccessEnabled, .remoteAllowLAN, .remoteRequireAuth, .remoteReadOnly,
        .remoteTLSEnabled, .remoteTLSIdentityPath,
        .remoteTrustedHeaderAuthEnabled, .remoteTrustedHeaderName, .remoteTrustedProxies,
    ]

    var body: some View {
        PaneScaffold(title: L10n.t("Web Access"),
                     subtitle: L10n.t("Run the full download manager in a browser — add, stream, and manage everything from your phone or another Mac.")) {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.managedKeys)

            SetRow(name: L10n.t("Enable web portal"),
                   desc: L10n.t("Serves the browser UI and JSON API on the port below.")) {
                SettingSwitch(isOn: enabledBinding)
                    .managed(.remoteAccessEnabled, vm.managedPolicy)
            }
            if vm.settings.remoteAccessEnabled {
                SetRow(name: L10n.t("Port"), desc: L10n.t("TCP port the embedded server listens on.")) {
                    SettingInt(value: setting(vm, \.remotePort), width: 70)
                }

                SetRow(name: L10n.t("Require sign-in"),
                       desc: L10n.t("Prompt for a username and password (recommended). Off = open access — only safe on localhost.")) {
                    SettingSwitch(isOn: setting(vm, \.remoteRequireAuth))
                        .managed(.remoteRequireAuth, vm.managedPolicy)
                }
                if vm.settings.remoteRequireAuth {
                    SetRow(name: L10n.t("Username"), desc: "") {
                        SettingText(text: setting(vm, \.remoteUsername), width: 150)
                    }
                    SetRow(name: L10n.t("Password"),
                           desc: vm.hasRemotePassword
                               ? L10n.t("A password is set. Type a new one to change it.")
                               : L10n.t("No password set yet — sign-in will fail until you set one.")) {
                        HStack(spacing: 8) {
                            SecureField("", text: $newPassword)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                                .accessibilityLabel(L10n.t("New portal password"))
                            Button(L10n.t("Set")) {
                                vm.setRemotePassword(newPassword)
                                newPassword = ""
                            }
                            .disabled(newPassword.isEmpty)
                            .accessibilityLabel(L10n.t("Set portal password"))
                        }
                    }
                }

                SetRow(name: L10n.t("Allow access from the network"),
                       desc: L10n.t("Off = this Mac only (localhost). On = any device on your LAN.")) {
                    SettingSwitch(isOn: setting(vm, \.remoteAllowLAN))
                        .managed(.remoteAllowLAN, vm.managedPolicy)
                }
                SetRow(name: L10n.t("Read-only mode"),
                       desc: L10n.t("Let clients view and stream, but not add, remove, or change downloads.")) {
                    SettingSwitch(isOn: setting(vm, \.remoteReadOnly))
                        .managed(.remoteReadOnly, vm.managedPolicy)
                }
                SetRow(name: L10n.t("Session timeout"),
                       desc: L10n.t("Minutes a browser stays signed in before re-login.")) {
                    SettingInt(value: setting(vm, \.remoteSessionMinutes), width: 70)
                }

                SetRow(name: L10n.t("Web theme"),
                       desc: L10n.t("The portal's look. Independent of the app theme — the desktop and the browser each keep their own.")) {
                    Picker("", selection: $vm.remoteTheme) {
                        ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel(L10n.t("Web portal theme"))
                }

                SetRow(name: L10n.t("API token"),
                       desc: L10n.t("For scripts and the browser extension. People should use the sign-in above.")) {
                    HStack(spacing: 8) {
                        Text(vm.settings.remoteToken)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150)
                            .accessibilityLabel(L10n.t("API token"))
                            .accessibilityValue(vm.settings.remoteToken.map { "\($0) " }.joined())
                        Button(L10n.t("Regenerate")) {
                            vm.settingsConfirm(
                                title: L10n.t("Regenerate the API token?"),
                                message: L10n.t("Existing portal links and the paired browser extension stop working until you copy the new token to them."),
                                confirmTitle: L10n.t("Regenerate"),
                                destructive: true
                            ) {
                                vm.update { $0.remoteToken = Self.newToken() }
                                vm.toastNow(L10n.t("New API token generated"))
                            }
                        }
                        .accessibilityLabel(L10n.t("Regenerate API token"))
                    }
                }
                if let failure = vm.remotePortalFailure {
                    SetRow(name: L10n.t("Web access is not running"), desc: failure) { EmptyView() }
                }
                SetRow(name: L10n.t("Open portal"), desc: L10n.t("Open it here, or from another device on your LAN.")) {
                    HStack(spacing: 8) {
                        Button(L10n.t("Open")) { if let url = controlURL { NSWorkspace.shared.open(url) } }
                            .disabled(controlURL == nil || vm.remotePortalFailure != nil)
                            .accessibilityLabel(L10n.t("Open web portal in browser"))
                        Button(L10n.t("Copy Link")) {
                            if let url = controlURL { vm.copyToPasteboard(url.absoluteString) }
                        }
                        .disabled(controlURL == nil || vm.remotePortalFailure != nil)
                        .accessibilityLabel(L10n.t("Copy web portal link"))
                    }
                }
                SectionHeader(L10n.t("Hardening"))
                SetRow(name: L10n.t("Serve over HTTPS"),
                       desc: L10n.t("Encrypt the portal with a PKCS#12 identity. If the identity can’t be loaded the server refuses to start rather than falling back to cleartext.")) {
                    SettingSwitch(isOn: setting(vm, \.remoteTLSEnabled))
                        .managed(.remoteTLSEnabled, vm.managedPolicy)
                }
                if vm.settings.remoteTLSEnabled {
                    SetRow(name: L10n.t("Identity (.p12) path"),
                           desc: L10n.t("Its passphrase is read from the GOEL_PORTAL_TLS_PASSPHRASE environment variable — Goel° never stores it.")) {
                        SettingText(text: setting(vm, \.remoteTLSIdentityPath), width: 200)
                            .managed(.remoteTLSIdentityPath, vm.managedPolicy)
                    }
                }
                SetRow(name: L10n.t("Failed sign-ins before backoff"),
                       desc: L10n.t("Wrong passwords from one address are slowed exponentially. The delay is per-address, so one attacker can’t lock everybody else out.")) {
                    SettingInt(value: setting(vm, \.remoteLoginMaxAttempts), width: 70)
                }
                SetRow(name: L10n.t("Backoff (seconds)"),
                       desc: L10n.t("The first delay after the limit is hit; it doubles from there.")) {
                    SettingInt(value: backoffSecondsBinding, width: 70)
                }

                SectionHeader(L10n.t("Single sign-on (advanced)"))
                SetRow(name: L10n.t("Trust a proxy’s identity header"),
                       desc: L10n.t("For an SSO reverse proxy that authenticates users itself. Only enable it behind such a proxy — otherwise anyone can set the header.")) {
                    SettingSwitch(isOn: setting(vm, \.remoteTrustedHeaderAuthEnabled))
                        .managed(.remoteTrustedHeaderAuthEnabled, vm.managedPolicy)
                }
                if vm.settings.remoteTrustedHeaderAuthEnabled {
                    SetRow(name: L10n.t("Header name"), desc: L10n.t("e.g. X-Forwarded-User.")) {
                        SettingText(text: setting(vm, \.remoteTrustedHeaderName), width: 180)
                            .managed(.remoteTrustedHeaderName, vm.managedPolicy)
                    }
                    SetRow(name: L10n.t("Trusted proxies"),
                           desc: L10n.t("Comma-separated IPs/CIDRs. Checked against the kernel-supplied peer address. EMPTY MEANS TRUST NOBODY — the header is ignored until you list one.")) {
                        SettingText(text: trustedProxiesBinding, width: 200)
                            .managed(.remoteTrustedProxies, vm.managedPolicy)
                    }
                }

                if vm.settings.remoteAllowLAN {
                    SetRow(name: L10n.t("Scan from your phone"),
                           desc: lanURL == nil
                               ? L10n.t("Advertised via Bonjour. No LAN address detected right now.")
                               : L10n.t("Point the camera at the code to open the portal. Also advertised via Bonjour.")) {
                        if let lanURL {
                            QRCodeView(text: lanURL.absoluteString)
                        }
                    }
                }
            }
        }
    }

    private var backoffSecondsBinding: Binding<Int> {
        Binding(
            get: { Int(vm.settings.remoteLoginBackoffSeconds.rounded()) },
            set: { seconds in
                vm.update { $0.remoteLoginBackoffSeconds = Double(max(0, seconds)) }
            }
        )
    }

    /// Blank entries must be dropped: a trailing comma would look configured but match nothing.
    private var trustedProxiesBinding: Binding<String> {
        Binding(
            get: { vm.settings.remoteTrustedProxies.joined(separator: ", ") },
            set: { raw in
                let parsed = raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                vm.update { $0.remoteTrustedProxies = parsed }
            }
        )
    }

    /// Must track the server, which fails closed onto TLS; an `http://` link would just not connect.
    private var scheme: String {
        vm.settings.remoteTLSEnabled ? "https" : "http"
    }

    private var lanURL: URL? {
        guard let ip = LANAddress.primaryIPv4() else { return nil }
        return URL(string: "\(scheme)://\(ip):\(vm.settings.remotePort)/?token=\(vm.settings.remoteToken)")
    }

    /// Mints the token on first enable, so the server never starts unauthenticated.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { vm.settings.remoteAccessEnabled },
            set: { enabled in
                vm.update {
                    $0.remoteAccessEnabled = enabled
                    if enabled, $0.remoteToken.isEmpty { $0.remoteToken = Self.newToken() }
                }
            }
        )
    }

    private var controlURL: URL? {
        URL(string: "\(scheme)://127.0.0.1:\(vm.settings.remotePort)/?token=\(vm.settings.remoteToken)")
    }

    // `nonisolated`: without it this inherits `View`'s main-actor isolation and won't compile inside `update`.
    private nonisolated static func newToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

struct BrowserIntegrationPane: View {
    @EnvironmentObject private var vm: AppViewModel

    private static let bookmarklet =
        "javascript:location.href='goeldownloader://add?url='+encodeURIComponent(location.href)"

    @State private var installResult: String?

    var body: some View {
        PaneScaffold(title: L10n.t("Browser Integration"),
                     subtitle: L10n.t("Capture downloads from your browser, or send links here by hand.")) {
            SectionHeader(L10n.t("Chrome, Edge, Brave & Firefox"))
            SetRow(name: L10n.t("1. Install the messaging helper"),
                   desc: installResult ?? L10n.t("Lets the extension talk to this app — nothing works without it. Writes per-browser manifests in your Library; no admin needed. Open a browser at least once first, and click this again if you ever move the app.")) {
                Button(L10n.t("Install Helper")) {
                    installResult = BrowserIntegrationService.installHostManifests()
                }
            }
            SetRow(name: L10n.t("2. Load the extension"),
                   desc: L10n.t("Chrome/Edge/Brave/Vivaldi/Arc: chrome://extensions → Developer mode → Load unpacked → this folder. Firefox 128+: about:debugging → Load Temporary Add-on → the folder’s manifest.json (Firefox forgets it on quit).")) {
                Button(L10n.t("Show Folder")) {
                    if let folder = BrowserIntegrationService.extensionFolder {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } else {
                        vm.settingsMessage(L10n.t("Browser Extension"),
                            L10n.t("The bundled extension folder is only available in the packaged app, not a dev build."))
                    }
                }
            }
            SetRow(name: L10n.t("3. Restart the browser"),
                   desc: L10n.t("Browsers read the helper’s manifest only at startup, so quit and reopen the browser fully — otherwise the extension reports that it can’t reach this app.")) {
                EmptyView()
            }
            SetRow(name: L10n.t("4. Capture"),
                   desc: L10n.t("Click the extension’s toolbar button to toggle capture of all downloads, or right-click any link → “Download with Goel°”. For files behind a login, use “(stay signed in)” and accept the cookie prompt.")) {
                EmptyView()
            }

            SectionHeader("Safari")
            SetRow(name: L10n.t("1. Open Safari’s extensions"),
                   desc: L10n.t("Safari finds the extension bundled inside this app — no helper and no loading needed. If you just installed the app, quit and reopen Safari once so it appears.")) {
                Button(L10n.t("Open Safari Extensions")) { openSafariExtensionPrefs() }
            }
            SetRow(name: L10n.t("2. Turn it on"),
                   desc: L10n.t("Enable “Goel° Capture” in the list, and allow it on the sites you use. An unsigned (ad-hoc) build also needs Safari → Develop menu → “Allow Unsigned Extensions” each session.")) {
                EmptyView()
            }
            SetRow(name: L10n.t("3. Capture"),
                   desc: L10n.t("Right-click a link → “Download with Goel°”. Safari-captured links open here with a quick confirmation.")) {
                EmptyView()
            }
            SetRow(name: L10n.t("What Safari can’t do"),
                   desc: L10n.t("No capture toggle (Safari has no downloads API) and no signed-in downloads: its sandbox can only reach this app through a URL, which macOS logs, so a session cookie is refused rather than written there. Use Chrome or Firefox for either.")) {
                EmptyView()
            }

            SectionHeader(L10n.t("Help"))
            SetRow(name: L10n.t("Full instructions"),
                   desc: L10n.t("Per-browser steps, what each browser supports, and fixes for the common failures.")) {
                Button(L10n.t("Open Guide")) {
                    if let url = URL(string: "https://github.com/vinitkumargoel/goel/blob/main/docs/browser-extension.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            SectionHeader(L10n.t("Without the extension"))
            SetRow(name: L10n.t("URL scheme"),
                   desc: L10n.t("goeldownloader://add?url=… opens and queues the link (packaged app).")) {
                Button(L10n.t("Copy Example")) {
                    vm.copyToPasteboard("goeldownloader://add?url=https%3A%2F%2Fexample.com%2Ffile.zip")
                }
            }
            SetRow(name: L10n.t("Bookmarklet"),
                   desc: L10n.t("Drag-save as a bookmark; clicking it sends the current page here.")) {
                Button(L10n.t("Copy Bookmarklet")) {
                    vm.copyToPasteboard(Self.bookmarklet)
                }
            }
            SetRow(name: L10n.t("Services menu"),
                   desc: L10n.t("Select a link in any app → right-click → Services → “Download with Goel°”.")) {
                EmptyView()
            }
            SetRow(name: L10n.t("Drop basket"),
                   desc: L10n.t("A small always-on-top target for dragging links out of the browser (⌘⇧B).")) {
                Button(L10n.t("Show")) { DropBasketController.shared.toggle() }
                    .accessibilityLabel(L10n.t("Show drop basket"))
            }
        }
    }

    private func openSafariExtensionPrefs() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: "com.goel.downloader.SafariExtension") { error in
            guard error != nil else { return }
            Task { @MainActor in
                vm.settingsMessage(L10n.t("Safari Extension"),
                    L10n.t("Couldn't open Safari's extension settings. Open Safari ▸ Settings ▸ Extensions manually — the extension only registers from the installed app."))
            }
        }
    }
}

struct CredentialsSection: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var entries: [HostCredential] = []
    @State private var newHost = ""
    @State private var newUser = ""
    @State private var newPassword = ""

    private let store: any CredentialManaging = KeychainCredentialStore()

    var body: some View {
        SectionHeader(L10n.t("Site logins"))
        Text(L10n.t("Stored in your Keychain. Sent as HTTP Basic auth when a download matches the host."))
            .scaledFont(size: 11.5)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 4)

        ForEach(entries) { entry in
            SetRow(name: entry.host, desc: L10n.t("User: %@", entry.username)) {
                Button {
                    vm.settingsConfirm(
                        title: L10n.t("Remove the saved login for %@?", entry.host),
                        message: L10n.t("The stored username and password are deleted from your Keychain."),
                        confirmTitle: L10n.t("Remove"),
                        destructive: true
                    ) {
                        store.removeCredential(host: entry.host)
                        refresh()
                        vm.toastNow(L10n.t("Login removed"))
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.t("Remove login"))
                .a11yButton(L10n.t("Remove saved login for %@", entry.host))
            }
        }

        SetRow(name: L10n.t("Host"), desc: L10n.t("e.g. files.example.com")) {
            SettingText(text: $newHost, width: 180)
        }
        SetRow(name: L10n.t("Username"), desc: "") {
            SettingText(text: $newUser, width: 180)
        }
        SetRow(name: L10n.t("Password"), desc: "") {
            SecureField("", text: $newPassword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel(L10n.t("Password for the new site login"))
        }
        SetRow(name: "", desc: "") {
            Button(L10n.t("Add Login")) {
                let host = newHost.trimmingCharacters(in: .whitespaces).lowercased()
                guard !host.isEmpty, !newUser.isEmpty else { return }
                store.setCredential(username: newUser, password: newPassword, host: host)
                newHost = ""; newUser = ""; newPassword = ""
                refresh()
            }
            .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty || newUser.isEmpty)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        entries = store.allCredentials()
    }
}

struct AuditLogPane: View {
    @EnvironmentObject private var vm: AppViewModel

    private static let managedKeys: [ManagedPolicy.Key] = [
        .auditLogEnabled, .auditLogDirectory, .auditLogRetentionDays,
        .auditLogKeepFiles, .auditLogMaxFileMegabytes,
    ]

    var body: some View {
        PaneScaffold(title: L10n.t("Audit Log"),
                     subtitle: L10n.t("An append-only record of downloads added, completed, and failed — written to a file on this Mac and nowhere else.")) {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.managedKeys)

            SetRow(name: L10n.t("Keep an audit log"),
                   desc: L10n.t("Off by default. Nothing is recorded, and nothing is ever sent anywhere — Goel° has no telemetry.")) {
                SettingSwitch(isOn: setting(vm, \.auditLogEnabled))
                    .managed(.auditLogEnabled, vm.managedPolicy)
            }
            if vm.settings.auditLogEnabled {
                SetRow(name: L10n.t("Folder"),
                       desc: L10n.t("Leave empty for Application Support/GoelDownloader/Audit. File names and hosts are recorded; URLs are reduced to their host.")) {
                    SettingText(text: setting(vm, \.auditLogDirectory), width: 200)
                        .managed(.auditLogDirectory, vm.managedPolicy)
                }
                SetRow(name: L10n.t("Rotate at (MB)"),
                       desc: L10n.t("The live file is rotated once it passes this size.")) {
                    SettingInt(value: setting(vm, \.auditLogMaxFileMegabytes), width: 70)
                        .managed(.auditLogMaxFileMegabytes, vm.managedPolicy)
                }
                SetRow(name: L10n.t("Rotated files to keep"),
                       desc: L10n.t("Older ones are deleted.")) {
                    SettingInt(value: setting(vm, \.auditLogKeepFiles), width: 70)
                        .managed(.auditLogKeepFiles, vm.managedPolicy)
                }
                SetRow(name: L10n.t("Keep for (days)"),
                       desc: L10n.t("Rotated files older than this are deleted. 0 keeps them forever.")) {
                    SettingInt(value: setting(vm, \.auditLogRetentionDays), width: 70)
                        .managed(.auditLogRetentionDays, vm.managedPolicy)
                }
                SetRow(name: L10n.t("Reveal in Finder"),
                       desc: L10n.t("Turning the log off never deletes what is already written — that record is not Goel°’s to discard.")) {
                    Button(L10n.t("Show Audit Folder")) { vm.revealAuditLogFolder() }
                }
            }
        }
    }
}
