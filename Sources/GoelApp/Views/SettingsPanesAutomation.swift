import SwiftUI
import AppKit
import SafariServices
import GoelCore

// The automation/integration settings panes added on top of the original six:
// Scheduler (auto-shutdown + download window), RSS auto-download, the real
// Remote Access pane, the Browser integration pane (URL scheme + bookmarklet),
// and the per-host credentials section used by the Network pane. Standalone
// views (not SettingsView extensions), so they share the free `setting(_:_:)`
// binding helper below rather than reaching into SettingsView's private API.

/// A two-way binding into `AppSettings` committing through `vm.update`. Shared
/// by these panes and by `SettingsView.binding` so the get/set lives once.
@MainActor
func setting<T>(_ vm: AppViewModel, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { vm.settings[keyPath: keyPath] },
        set: { newValue in vm.update { $0[keyPath: keyPath] = newValue } }
    )
}

// MARK: - Scheduler pane

struct SchedulerPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        PaneScaffold(title: "Scheduler",
                     subtitle: "Download windows, scheduled profiles, and what happens when the queue finishes.") {
            SectionHeader("When downloads finish")
            SetRow(name: "Then", desc: "One-shot — resets to “Do nothing” after it fires.") {
                Dropdown(selection: setting(vm, \.autoShutdownAction), items: [
                    .option("none", "Do nothing"),
                    .option("quit", "Quit Goel°"),
                    .option("sleep", "Sleep"),
                    .option("shutdown", "Shut down"),
                ], width: 180)
            }

            SectionHeader("Download window")
            SetRow(name: "Only download during a daily window",
                   desc: "Outside the window active downloads pause and queued ones wait.") {
                SettingSwitch(isOn: setting(vm, \.scheduleEnabled))
            }
            if vm.settings.scheduleEnabled {
                SetRow(name: "Start", desc: "") {
                    Dropdown(selection: setting(vm, \.scheduleStartMinute), items: Self.timeOptions, width: 110)
                }
                SetRow(name: "End", desc: "An end before the start wraps past midnight.") {
                    Dropdown(selection: setting(vm, \.scheduleEndMinute), items: Self.timeOptions, width: 110)
                }
                SetRow(name: "Days", desc: "") {
                    Dropdown(selection: daysBinding, items: [
                        .option("all", "Every day"),
                        .option("weekdays", "Weekdays"),
                        .option("weekend", "Weekends"),
                    ], width: 130)
                }
                SetRow(name: "Profile inside the window",
                       desc: "Switch traffic profiles while the window is open (restored after).") {
                    Dropdown(selection: setting(vm, \.scheduleProfileName),
                             items: [Dropdown<String>.Item.option("", "Keep current")]
                                + vm.settings.profiles.map { .option($0.name, $0.name) },
                             width: 140)
                }
            }
        }
    }

    /// Hourly options for the window pickers, "00:00" … "23:00".
    private static let timeOptions: [Dropdown<Int>.Item] =
        stride(from: 0, to: 1440, by: 60).map { minutes in
            .option(minutes, String(format: "%02d:%02d", minutes / 60, minutes % 60))
        }

    /// The day set as a coarse preset (every day / weekdays / weekends).
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

// MARK: - RSS pane

struct RSSPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var newURL = ""
    @State private var newPattern = ""
    @State private var newStartPaused = false

    var body: some View {
        PaneScaffold(title: "RSS Feeds",
                     subtitle: "Watch feeds and queue new items automatically (podcasts, releases, torrent feeds).") {
            SetRow(name: "Check feeds every", desc: "") {
                Dropdown(selection: setting(vm, \.rssPollIntervalMinutes), items: [
                    .option(15, "15 minutes"),
                    .option(30, "30 minutes"),
                    .option(60, "Hour"),
                    .option(360, "6 hours"),
                ], width: 130)
            }

            SectionHeader("Feeds")
            if vm.settings.rssFeeds.isEmpty {
                Text("No feeds yet — add one below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(vm.settings.rssFeeds) { feed in
                SetRow(name: feed.url,
                       desc: feed.titlePattern.isEmpty
                           ? "Every item\(feed.startPaused ? " · added paused" : "")"
                           : "Titles containing “\(feed.titlePattern)”\(feed.startPaused ? " · added paused" : "")") {
                    HStack(spacing: 10) {
                        SettingSwitch(isOn: feedEnabledBinding(feed.id))
                        Button {
                            vm.update { $0.rssFeeds.removeAll { $0.id == feed.id } }
                            vm.toastNow("Feed removed")
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove feed")
                        // Name the feed: a list of these is otherwise a column
                        // of identical unlabelled destructive buttons.
                        .a11yButton("Remove feed \(feed.url)")
                    }
                }
            }

            SectionHeader("Add a feed")
            SetRow(name: "Feed URL", desc: "RSS 2.0 or Atom.") {
                SettingText(text: $newURL, width: 220)
            }
            SetRow(name: "Title contains", desc: "Leave empty to take every item.") {
                SettingText(text: $newPattern, width: 160)
            }
            SetRow(name: "Add items paused", desc: "Review matches before any bytes move.") {
                SettingSwitch(isOn: $newStartPaused)
            }
            SetRow(name: "", desc: "") {
                Button("Add Feed") { addFeed() }
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
        vm.toastNow("Feed added")
    }
}

// MARK: - Web Access pane

struct RemoteAccessPane: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Local scratch for the password field — never bound to settings (the
    /// plaintext is hashed on "Set" and only the hash is persisted).
    @State private var newPassword = ""

    /// Every policy key this pane renders a control for, so the notice appears
    /// whenever any one of them is locked rather than only for the obvious ones.
    private static let managedKeys: [ManagedPolicy.Key] = [
        .remoteAccessEnabled, .remoteAllowLAN, .remoteRequireAuth, .remoteReadOnly,
        .remoteTLSEnabled, .remoteTLSIdentityPath,
        .remoteTrustedHeaderAuthEnabled, .remoteTrustedHeaderName, .remoteTrustedProxies,
    ]

    var body: some View {
        PaneScaffold(title: "Web Access",
                     subtitle: "Run the full download manager in a browser — add, stream, and manage everything from your phone or another Mac.") {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.managedKeys)

            SetRow(name: "Enable web portal",
                   desc: "Serves the browser UI and JSON API on the port below.") {
                SettingSwitch(isOn: enabledBinding)
                    .managed(.remoteAccessEnabled, vm.managedPolicy)
            }
            if vm.settings.remoteAccessEnabled {
                SetRow(name: "Port", desc: "TCP port the embedded server listens on.") {
                    SettingInt(value: setting(vm, \.remotePort), width: 70)
                }

                SetRow(name: "Require sign-in",
                       desc: "Prompt for a username and password (recommended). Off = open access — only safe on localhost.") {
                    SettingSwitch(isOn: setting(vm, \.remoteRequireAuth))
                        .managed(.remoteRequireAuth, vm.managedPolicy)
                }
                if vm.settings.remoteRequireAuth {
                    SetRow(name: "Username", desc: "") {
                        SettingText(text: setting(vm, \.remoteUsername), width: 150)
                    }
                    SetRow(name: "Password",
                           desc: vm.hasRemotePassword
                               ? "A password is set. Type a new one to change it."
                               : "No password set yet — sign-in will fail until you set one.") {
                        HStack(spacing: 8) {
                            SecureField("", text: $newPassword)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                                // `SetRow`'s environment name only reaches the
                                // four `Setting*` wrappers; a raw `SecureField`
                                // with an empty prompt is an anonymous field.
                                .accessibilityLabel("New portal password")
                            Button("Set") {
                                vm.setRemotePassword(newPassword)
                                newPassword = ""
                            }
                            .disabled(newPassword.isEmpty)
                            .accessibilityLabel("Set portal password")
                        }
                    }
                }

                SetRow(name: "Allow access from the network",
                       desc: "Off = this Mac only (localhost). On = any device on your LAN.") {
                    SettingSwitch(isOn: setting(vm, \.remoteAllowLAN))
                        .managed(.remoteAllowLAN, vm.managedPolicy)
                }
                SetRow(name: "Read-only mode",
                       desc: "Let clients view and stream, but not add, remove, or change downloads.") {
                    SettingSwitch(isOn: setting(vm, \.remoteReadOnly))
                        .managed(.remoteReadOnly, vm.managedPolicy)
                }
                SetRow(name: "Session timeout",
                       desc: "Minutes a browser stays signed in before re-login.") {
                    SettingInt(value: setting(vm, \.remoteSessionMinutes), width: 70)
                }

                SetRow(name: "Web theme",
                       desc: "The portal's look. Independent of the app theme — the desktop and the browser each keep their own.") {
                    Picker("", selection: $vm.remoteTheme) {
                        ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel("Web portal theme")
                }

                SetRow(name: "API token",
                       desc: "For scripts and the browser extension. People should use the sign-in above.") {
                    HStack(spacing: 8) {
                        Text(vm.settings.remoteToken)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150)
                            // Visually truncated in the middle, so the *visible*
                            // string isn't the token. Give the element the whole
                            // value, spelled character by character — a 32-hex
                            // token read as words is unusable.
                            .accessibilityLabel("API token")
                            .accessibilityValue(vm.settings.remoteToken.map { "\($0) " }.joined())
                        Button("Regenerate") {
                            vm.settingsConfirm(
                                title: "Regenerate the API token?",
                                message: "Existing portal links and the paired browser extension stop working until you copy the new token to them.",
                                confirmTitle: "Regenerate",
                                destructive: true
                            ) {
                                vm.update { $0.remoteToken = Self.newToken() }
                                vm.toastNow("New API token generated")
                            }
                        }
                        .accessibilityLabel("Regenerate API token")
                    }
                }
                if let failure = vm.remotePortalFailure {
                    SetRow(name: "Web access is not running", desc: failure) { EmptyView() }
                }
                SetRow(name: "Open portal", desc: "Open it here, or from another device on your LAN.") {
                    HStack(spacing: 8) {
                        Button("Open") { if let url = controlURL { NSWorkspace.shared.open(url) } }
                            .disabled(controlURL == nil || vm.remotePortalFailure != nil)
                            .accessibilityLabel("Open web portal in browser")
                        Button("Copy Link") {
                            if let url = controlURL { vm.copyToPasteboard(url.absoluteString) }
                        }
                        .disabled(controlURL == nil || vm.remotePortalFailure != nil)
                        .accessibilityLabel("Copy web portal link")
                    }
                }
                SectionHeader("Hardening")
                SetRow(name: "Serve over HTTPS",
                       desc: "Encrypt the portal with a PKCS#12 identity. If the identity can’t be loaded the server refuses to start rather than falling back to cleartext.") {
                    SettingSwitch(isOn: setting(vm, \.remoteTLSEnabled))
                        .managed(.remoteTLSEnabled, vm.managedPolicy)
                }
                if vm.settings.remoteTLSEnabled {
                    SetRow(name: "Identity (.p12) path",
                           desc: "Its passphrase is read from the GOEL_PORTAL_TLS_PASSPHRASE environment variable — Goel° never stores it.") {
                        SettingText(text: setting(vm, \.remoteTLSIdentityPath), width: 200)
                            .managed(.remoteTLSIdentityPath, vm.managedPolicy)
                    }
                }
                SetRow(name: "Failed sign-ins before backoff",
                       desc: "Wrong passwords from one address are slowed exponentially. The delay is per-address, so one attacker can’t lock everybody else out.") {
                    SettingInt(value: setting(vm, \.remoteLoginMaxAttempts), width: 70)
                }
                SetRow(name: "Backoff (seconds)",
                       desc: "The first delay after the limit is hit; it doubles from there.") {
                    SettingInt(value: backoffSecondsBinding, width: 70)
                }

                SectionHeader("Single sign-on (advanced)")
                SetRow(name: "Trust a proxy’s identity header",
                       desc: "For an SSO reverse proxy that authenticates users itself. Only enable it behind such a proxy — otherwise anyone can set the header.") {
                    SettingSwitch(isOn: setting(vm, \.remoteTrustedHeaderAuthEnabled))
                        .managed(.remoteTrustedHeaderAuthEnabled, vm.managedPolicy)
                }
                if vm.settings.remoteTrustedHeaderAuthEnabled {
                    SetRow(name: "Header name", desc: "e.g. X-Forwarded-User.") {
                        SettingText(text: setting(vm, \.remoteTrustedHeaderName), width: 180)
                            .managed(.remoteTrustedHeaderName, vm.managedPolicy)
                    }
                    SetRow(name: "Trusted proxies",
                           desc: "Comma-separated IPs/CIDRs. Checked against the kernel-supplied peer address. EMPTY MEANS TRUST NOBODY — the header is ignored until you list one.") {
                        SettingText(text: trustedProxiesBinding, width: 200)
                            .managed(.remoteTrustedProxies, vm.managedPolicy)
                    }
                }

                if vm.settings.remoteAllowLAN {
                    SetRow(name: "Scan from your phone",
                           desc: lanURL == nil
                               ? "Advertised via Bonjour. No LAN address detected right now."
                               : "Point the camera at the code to open the portal. Also advertised via Bonjour.") {
                        if let lanURL {
                            QRCodeView(text: lanURL.absoluteString)
                        }
                    }
                }
            }
        }
    }

    /// Whole seconds onto the stored `Double`. The backoff is configured in
    /// seconds by an operator; sub-second precision would be noise.
    private var backoffSecondsBinding: Binding<Int> {
        Binding(
            get: { Int(vm.settings.remoteLoginBackoffSeconds.rounded()) },
            set: { seconds in
                vm.update { $0.remoteLoginBackoffSeconds = Double(max(0, seconds)) }
            }
        )
    }

    /// A comma-separated view onto the stored list. Blank entries are dropped so
    /// a trailing comma can't become an empty — and therefore never-matching —
    /// entry that looks like a configured proxy.
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

    /// The scheme the portal is actually listening with. `RemoteControlServer`
    /// binds TLS parameters when `remoteTLSEnabled` is set and fails closed rather
    /// than falling back, so the socket then speaks *only* TLS — handing out an
    /// `http://` link would make a correctly running portal look broken.
    private var scheme: String {
        vm.settings.remoteTLSEnabled ? "https" : "http"
    }

    /// The LAN-reachable control URL, when a LAN address exists.
    private var lanURL: URL? {
        guard let ip = LANAddress.primaryIPv4() else { return nil }
        return URL(string: "\(scheme)://\(ip):\(vm.settings.remotePort)/?token=\(vm.settings.remoteToken)")
    }

    /// Enabling generates a token on first use, so the server never starts
    /// unauthenticated.
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

    /// The loopback control URL. Optional because the port field accepts any
    /// `Int` (including negatives), which makes `URL(string:)` return nil.
    private var controlURL: URL? {
        URL(string: "\(scheme)://127.0.0.1:\(vm.settings.remotePort)/?token=\(vm.settings.remoteToken)")
    }

    private static func newToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

// MARK: - Browser pane

struct BrowserIntegrationPane: View {
    @EnvironmentObject private var vm: AppViewModel

    private static let bookmarklet =
        "javascript:location.href='goeldownloader://add?url='+encodeURIComponent(location.href)"

    @State private var installResult: String?

    var body: some View {
        PaneScaffold(title: "Browser Integration",
                     subtitle: "Capture downloads from your browser, or send links here by hand.") {
            SectionHeader("Chrome, Edge, Brave & Firefox")
            SetRow(name: "1. Load the extension",
                   desc: "Chrome/Edge/Brave: chrome://extensions → Developer mode → Load unpacked → this folder. Firefox: about:debugging → Load Temporary Add-on.") {
                Button("Show Folder") {
                    if let folder = BrowserIntegrationService.extensionFolder {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } else {
                        vm.settingsMessage("Browser Extension",
                            "The bundled extension folder is only available in the packaged app, not a dev build.")
                    }
                }
            }
            SetRow(name: "2. Install the messaging helper",
                   desc: installResult ?? "Lets the extension talk to the app. Writes per-browser manifests in your Library — no admin needed.") {
                Button("Install Helper") {
                    installResult = BrowserIntegrationService.installHostManifests()
                }
            }
            SetRow(name: "3. Capture",
                   desc: "Click the extension's toolbar button to toggle capture of all downloads, or right-click any link → “Download with Goel°”.") {
                EmptyView()
            }

            SectionHeader("Safari")
            SetRow(name: "1. Open Safari’s extensions",
                   desc: "Safari finds the extension bundled inside this app. If you just installed the app, quit and reopen Safari once so it appears.") {
                Button("Open Safari Extensions") { openSafariExtensionPrefs() }
            }
            SetRow(name: "2. Turn it on",
                   desc: "Enable “Goel° Capture” in the list. An unsigned (ad-hoc) build also needs Safari → Develop menu → “Allow Unsigned Extensions” each session.") {
                EmptyView()
            }
            SetRow(name: "3. Capture",
                   desc: "Right-click a link → “Download with Goel°”. Safari-captured links open here with a quick confirmation.") {
                EmptyView()
            }

            SectionHeader("Without the extension")
            SetRow(name: "URL scheme",
                   desc: "goeldownloader://add?url=… opens and queues the link (packaged app).") {
                Button("Copy Example") {
                    vm.copyToPasteboard("goeldownloader://add?url=https%3A%2F%2Fexample.com%2Ffile.zip")
                }
            }
            SetRow(name: "Bookmarklet",
                   desc: "Drag-save as a bookmark; clicking it sends the current page here.") {
                Button("Copy Bookmarklet") {
                    vm.copyToPasteboard(Self.bookmarklet)
                }
            }
            SetRow(name: "Services menu",
                   desc: "Select a link in any app → right-click → Services → “Download with Goel°”.") {
                EmptyView()
            }
            SetRow(name: "Drop basket",
                   desc: "A small always-on-top target for dragging links out of the browser (⌘⇧B).") {
                // "Show" alone names nothing; there are three other buttons in
                // this pane and a screen reader lists them out of context.
                Button("Show") { DropBasketController.shared.toggle() }
                    .accessibilityLabel("Show drop basket")
            }
        }
    }

    /// Jump straight to this app's entry in Safari's extension settings. This only
    /// works from the packaged, signed `.app` (Safari must have registered the
    /// bundled `.appex`); from a dev build it fails, so surface that instead of
    /// leaving the button feeling dead.
    private func openSafariExtensionPrefs() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: "com.goel.downloader.SafariExtension") { error in
            guard error != nil else { return }
            Task { @MainActor in
                vm.settingsMessage("Safari Extension",
                    "Couldn't open Safari's extension settings. Open Safari ▸ Settings ▸ Extensions manually — the extension only registers from the installed app.")
            }
        }
    }
}

// MARK: - Per-host credentials (Network pane section)

struct CredentialsSection: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var entries: [HostCredential] = []
    @State private var newHost = ""
    @State private var newUser = ""
    @State private var newPassword = ""

    private let store: any CredentialManaging = KeychainCredentialStore()

    var body: some View {
        SectionHeader("Site logins")
        Text("Stored in your Keychain. Sent as HTTP Basic auth when a download matches the host.")
            .scaledFont(size: 11.5)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 4)

        ForEach(entries) { entry in
            SetRow(name: entry.host, desc: "User: \(entry.username)") {
                Button {
                    vm.settingsConfirm(
                        title: "Remove the saved login for \(entry.host)?",
                        message: "The stored username and password are deleted from your Keychain.",
                        confirmTitle: "Remove",
                        destructive: true
                    ) {
                        store.removeCredential(host: entry.host)
                        refresh()
                        vm.toastNow("Login removed")
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove login")
                .a11yButton("Remove saved login for \(entry.host)")
            }
        }

        SetRow(name: "Host", desc: "e.g. files.example.com") {
            SettingText(text: $newHost, width: 180)
        }
        SetRow(name: "Username", desc: "") {
            SettingText(text: $newUser, width: 180)
        }
        SetRow(name: "Password", desc: "") {
            SecureField("", text: $newPassword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("Password for the new site login")
        }
        SetRow(name: "", desc: "") {
            Button("Add Login") {
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

// MARK: - Audit log

/// The compliance-log pane.
///
/// Deliberately blunt about what this is and is not: the log is strictly local,
/// off by default, and nothing here ever transmits anything. "No telemetry" is a
/// product guarantee, and an *audit* feature is exactly where a user would
/// reasonably fear it had been quietly walked back — so the pane says so.
struct AuditLogPane: View {
    @EnvironmentObject private var vm: AppViewModel

    private static let managedKeys: [ManagedPolicy.Key] = [
        .auditLogEnabled, .auditLogDirectory, .auditLogRetentionDays,
        .auditLogKeepFiles, .auditLogMaxFileMegabytes,
    ]

    var body: some View {
        PaneScaffold(title: "Audit Log",
                     subtitle: "An append-only record of downloads added, completed, and failed — written to a file on this Mac and nowhere else.") {
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.managedKeys)

            SetRow(name: "Keep an audit log",
                   desc: "Off by default. Nothing is recorded, and nothing is ever sent anywhere — Goel° has no telemetry.") {
                SettingSwitch(isOn: setting(vm, \.auditLogEnabled))
                    .managed(.auditLogEnabled, vm.managedPolicy)
            }
            if vm.settings.auditLogEnabled {
                SetRow(name: "Folder",
                       desc: "Leave empty for Application Support/GoelDownloader/Audit. File names and hosts are recorded; URLs are reduced to their host.") {
                    SettingText(text: setting(vm, \.auditLogDirectory), width: 200)
                        .managed(.auditLogDirectory, vm.managedPolicy)
                }
                SetRow(name: "Rotate at (MB)",
                       desc: "The live file is rotated once it passes this size.") {
                    SettingInt(value: setting(vm, \.auditLogMaxFileMegabytes), width: 70)
                        .managed(.auditLogMaxFileMegabytes, vm.managedPolicy)
                }
                SetRow(name: "Rotated files to keep",
                       desc: "Older ones are deleted.") {
                    SettingInt(value: setting(vm, \.auditLogKeepFiles), width: 70)
                        .managed(.auditLogKeepFiles, vm.managedPolicy)
                }
                SetRow(name: "Keep for (days)",
                       desc: "Rotated files older than this are deleted. 0 keeps them forever.") {
                    SettingInt(value: setting(vm, \.auditLogRetentionDays), width: 70)
                        .managed(.auditLogRetentionDays, vm.managedPolicy)
                }
                SetRow(name: "Reveal in Finder",
                       desc: "Turning the log off never deletes what is already written — that record is not Goel°’s to discard.") {
                    Button("Show Audit Folder") { vm.revealAuditLogFolder() }
                }
            }
        }
    }
}
