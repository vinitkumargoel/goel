import SwiftUI
import AppKit
import GoelCore

struct SFTPConnectionEditor: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private let existing: SFTPConnection?

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var initialPath: String
    @State private var useAgent: Bool
    @State private var privateKeyPath: String
    @State private var keyPassphrase: String
    /// An untouched passphrase field means "keep the stored passphrase", not "clear it".
    @State private var keyPassphraseEdited = false

    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var hostKeyReset = false
    /// Must be an `.alert`: the shared confirm dialog is an overlay on `RootView`, so this sheet would hide it.
    @State private var confirmingHostKeyReset = false

    private enum TestResult {
        case success(String)
        case failure(String, detail: String?, retry: RetryAction? = nil)
    }

    private enum RetryAction { case test, save }

    init(existing: SFTPConnection?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: existing?.host ?? "")
        _port = State(initialValue: String(existing?.port ?? 22))
        _username = State(initialValue: existing?.username ?? "")
        _password = State(initialValue: "")
        _initialPath = State(initialValue: existing?.initialPath ?? ".")
        _useAgent = State(initialValue: existing?.useAgent ?? false)
        _privateKeyPath = State(initialValue: existing?.privateKeyPath ?? "")
        _keyPassphrase = State(initialValue: "")
    }

    private var portNumber: Int {
        guard let n = Int(port), (1...65535).contains(n) else { return 22 }
        return n
    }
    /// Guards Save/Test so invalid text is never silently coerced to 22 behind the user's back.
    private var portIsValid: Bool {
        guard let n = Int(port) else { return false }
        return (1...65535).contains(n)
    }
    private var saveBlocker: String? {
        SFTPConnectionForm.saveBlocker(host: host, username: username, portIsValid: portIsValid)
    }
    private var canSave: Bool { saveBlocker == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(systemImage: "server.rack",
                        title: existing == nil ? L10n.t("Add SFTP Server") : L10n.t("Edit SFTP Server"))
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field(L10n.t("Name"), L10n.t("My Server (optional)"), $name)
                    HStack(spacing: 10) {
                        field(L10n.t("Host"), "example.com", $host, required: true).frame(maxWidth: .infinity)
                        field(L10n.t("Port"), "22", $port).frame(width: 80)
                    }
                    if !portIsValid {
                        Text(L10n.t("Port must be a number between 1 and 65535."))
                            .scaledFont(size: Theme.TextSize.caption).foregroundStyle(Theme.red)
                    }
                    field(L10n.t("Username"), L10n.t("user"), $username, required: true)
                    labeled(L10n.t("Password")) {
                        SecureField(existing == nil ? L10n.t("password") : L10n.t("•••••• (unchanged)"), text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    privateKeyControls
                    field(L10n.t("Start folder"), ".", $initialPath)
                    Toggle(L10n.t("Also try the SSH agent"), isOn: $useAgent)
                        .scaledFont(size: Theme.TextSize.body)

                    if existing != nil { hostKeyResetControl }

                    if let result = testResult { testResultView(result) }
                }
                .padding(20)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let saveBlocker {
                    Text(saveBlocker)
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.t("Save is unavailable. %@", saveBlocker))
                }
                HStack {
                    Button(L10n.t("Test")) { runTest() }
                        .disabled(!canSave || testing)
                        .help(saveBlocker ?? L10n.t("Try to connect with these settings"))
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(L10n.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L10n.t("Save")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                        .help(saveBlocker ?? "")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460)
        .alert(L10n.t("Reset the pinned host key?"), isPresented: $confirmingHostKeyReset) {
            Button(L10n.t("Cancel"), role: .cancel) { }
            Button(L10n.t("Reset Key"), role: .destructive) { resetPinnedHostKey() }
        } message: {
            Text(L10n.t("Goel will trust whatever key %@ presents next. Only do this after a legitimate server rekey, then re-verify with Test.", pinnedEndpointHost))
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>,
                       required: Bool = false) -> some View {
        labeled(label, required: required) {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }

    private func labeled<Content: View>(_ label: String, required: Bool = false,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(required ? L10n.t("%@ *", label) : label)
                .scaledFont(size: Theme.TextSize.meta, weight: .semibold)
                .foregroundStyle(.secondary)
                .accessibilityLabel(required ? L10n.t("%@, required", label) : label)
            content()
        }
    }

    @ViewBuilder
    private var privateKeyControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeled(L10n.t("Private key")) {
                HStack(spacing: 8) {
                    TextField(L10n.t("None — password or agent only"), text: $privateKeyPath)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .scaledFont(size: Theme.TextSize.meta, design: .monospaced)
                        .help(L10n.t("Path to an SSH private key, e.g. ~/.ssh/id_ed25519"))
                    Button(L10n.t("Choose…")) { chooseKey() }
                    if !privateKeyPath.isEmpty {
                        Button {
                            privateKeyPath = ""
                            keyPassphrase = ""
                            keyPassphraseEdited = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(L10n.t("Remove the private key"))
                        .a11yButton(L10n.t("Remove the private key"))
                    }
                }
            }
            if !privateKeyPath.isEmpty {
                labeled(L10n.t("Key passphrase")) {
                    SecureField(existing?.privateKeyPath == nil ? L10n.t("leave blank if the key has none")
                                                               : L10n.t("•••••• (unchanged)"),
                                text: $keyPassphrase)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: keyPassphrase) { _, _ in keyPassphraseEdited = true }
                }
                if !FileManager.default.isReadableFile(atPath: expandedKeyPath) {
                    Text(L10n.t("Goel can't read that file — check the path and its permissions."))
                        .scaledFont(size: Theme.TextSize.caption).foregroundStyle(Theme.red)
                }
            }
        }
    }

    /// libssh2 does no tilde expansion, so `~` must be resolved before it or the readability check sees the path.
    private var expandedKeyPath: String {
        (privateKeyPath as NSString).expandingTildeInPath
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = L10n.t("Choose an SSH private key (for example id_ed25519 — not the .pub file).")
        panel.prompt = L10n.t("Choose")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
            testResult = nil
        }
    }

    /// Drops the pinned SSH fingerprint: the next connection trusts whatever key is presented, so this is rekey-only.
    @ViewBuilder
    private var hostKeyResetControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                confirmingHostKeyReset = true
            } label: {
                Label(L10n.t("Reset pinned host key"), systemImage: "key.slash")
                    .scaledFont(size: 11)
            }
            .buttonStyle(.link)
            .help(L10n.t("Forget the saved SSH host-key fingerprint. Use this only after a legitimate server rekey, then re-verify with Test."))
            if hostKeyReset {
                Text(L10n.t("Pinned key cleared — Goel will ask you to confirm the key on the next connection."))
                    .scaledFont(size: 10).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        switch result {
        case .success(let fp):
            VStack(alignment: .leading, spacing: 3) {
                Label(L10n.t("Connected successfully"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.green).scaledFont(size: 12, weight: .semibold)
                Text(L10n.t("Host key SHA-256:")).scaledFont(size: 10).foregroundStyle(.secondary)
                    .a11yDecorative()
                Text(fp).scaledFont(size: 10, design: .monospaced)
                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    // Spelled out character by character: base64 read as words cannot be checked against `ssh-keygen -lf`.
                    .accessibilityLabel(L10n.t("Host key SHA-256 fingerprint"))
                    .accessibilityValue(fp.map { "\($0) " }.joined())
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("Connection test succeeded"))
        case .failure(let message, let detail, let retry):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Theme.red).scaledFont(size: 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L10n.t("Connection test failed. %@", message))
                if let retry {
                    Button {
                        switch retry {
                        case .test: runTest()
                        case .save: save()
                        }
                    } label: {
                        Label(L10n.t("Try again"), systemImage: "arrow.clockwise")
                            .scaledFont(size: 11)
                    }
                    .disabled(testing)
                }
                if let detail {
                    DisclosureGroup(L10n.t("Technical detail")) {
                        Text(detail)
                            .scaledFont(size: Theme.TextSize.caption, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scaledFont(size: Theme.TextSize.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The pin belongs to the saved endpoint, not the draft: host/port may have been edited since.
    private var pinnedEndpointHost: String { existing?.host ?? host }
    private var pinnedEndpointPort: Int { existing?.port ?? portNumber }

    private func resetPinnedHostKey() {
        guard HostKeyStore.shared.reset(host: pinnedEndpointHost, port: pinnedEndpointPort) else {
            testResult = .failure(L10n.t("Goel couldn’t clear the saved host key for %@.", pinnedEndpointHost),
                                  detail: nil)
            return
        }
        testResult = nil
        hostKeyReset = true
        // Pooled connections carry the pin they were built with; without this the live one still demands the old key.
        let endpoint = SFTPTarget(host: pinnedEndpointHost, port: pinnedEndpointPort,
                                  username: existing?.username ?? username, password: nil)
        Task { await SFTPSessionPool.shared.disconnectAll(matching: endpoint) }
    }

    private func draftConnection() -> SFTPConnection {
        // libssh2 opens the key with plain fopen(), so a literal "~/.ssh/id_ed25519" would never resolve.
        let key = privateKeyPath.trimmingCharacters(in: .whitespaces)
        return SFTPConnection(id: existing?.id ?? UUID(),
                              name: name, host: host, port: portNumber,
                              username: username,
                              initialPath: initialPath.isEmpty ? "." : initialPath,
                              useAgent: useAgent,
                              privateKeyPath: key.isEmpty ? nil : (key as NSString).expandingTildeInPath)
    }

    /// Deliberately does not pre-fetch the stored secret — that meant two Keychain prompts per Test.
    private func testPassword() -> String? {
        password.isEmpty ? nil : password
    }

    private func testKeyPassphrase() -> String? {
        keyPassphraseEdited ? keyPassphrase : nil
    }

    private func runTest() {
        testing = true
        testResult = nil
        let connection = draftConnection()
        let pw = testPassword()
        let phrase = testKeyPassphrase()
        Task {
            // Explicit `password:` avoids re-pulling a stale secret; `credentialIdentity:` because secrets are keyed by user@host:port, which may have been edited.
            let client: SFTPClient
            switch SFTPSession.resolve(for: connection, password: pw, keyPassphrase: phrase,
                                       credentialIdentity: existing) {
            case .ready(let c):
                client = c
            case .incomplete:
                testing = false
                testResult = .failure(L10n.t("Enter a host and username first."), detail: nil)
                return
            case .credentialsUnavailable(let lookup):
                let e = SFTPError.credentialsUnavailable(lookup, host: connection.host)
                testing = false
                testResult = .failure(e.message, detail: e.detail,
                                      retry: lookup.isRetryable ? .test : nil)
                return
            }
            do {
                let fingerprint = try await client.probe()
                testing = false
                testResult = .success(fingerprint)
            } catch let e as SFTPError {
                testing = false
                testResult = .failure(e.message, detail: e.detail,
                                      retry: e.kind == .credentialsUnavailable ? .test : nil)
            } catch {
                testing = false
                testResult = .failure(error.localizedDescription, detail: nil)
            }
        }
    }

    private func save() {
        let isNew = existing == nil
        let result = vm.saveServer(draftConnection(),
                                   password: password.isEmpty ? nil : password,
                                   keyPassphrase: keyPassphraseEdited ? keyPassphrase : nil)
        // The profile never reached disk; the view model already said why, so don't
        // follow it with Keychain copy that implies the server was saved.
        guard case .saved(let outcome) = result else { return }
        guard outcome.didStore else {
            testResult = .failure(
                outcome.isRetryable
                    ? L10n.t("The server was saved, but Goel wasn't allowed to store the secret in your Keychain. Choose Allow when macOS asks, then try again.")
                    : L10n.t("The server was saved, but its secret couldn't be written to your Keychain."),
                detail: outcome.statusDetail,
                retry: outcome.isRetryable ? .save : nil)
            return
        }
        vm.toastNow(isNew ? L10n.t("Server added") : L10n.t("Server saved"))
        dismiss()
    }
}
