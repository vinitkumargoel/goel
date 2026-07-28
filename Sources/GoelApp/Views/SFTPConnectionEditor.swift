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
    private var canSave: Bool { !host.isEmpty && !username.isEmpty && portIsValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Add SFTP Server" : "Edit SFTP Server")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Name", "My Server (optional)", $name)
                    HStack(spacing: 10) {
                        field("Host", "example.com", $host).frame(maxWidth: .infinity)
                        field("Port", "22", $port).frame(width: 80)
                    }
                    if !portIsValid {
                        Text("Port must be a number between 1 and 65535.")
                            .font(.system(size: 10)).foregroundStyle(Theme.red)
                    }
                    field("Username", "user", $username)
                    labeled("Password") {
                        SecureField(existing == nil ? "password" : "•••••• (unchanged)", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    privateKeyControls
                    field("Start folder", ".", $initialPath)
                    Toggle("Also try the SSH agent", isOn: $useAgent)
                        .font(.system(size: 12))

                    if existing != nil { hostKeyResetControl }

                    if let result = testResult { testResultView(result) }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Test") { runTest() }
                    .disabled(!canSave || testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460)
        .alert("Reset the pinned host key?", isPresented: $confirmingHostKeyReset) {
            Button("Cancel", role: .cancel) { }
            Button("Reset Key", role: .destructive) { resetPinnedHostKey() }
        } message: {
            Text("Goel will trust whatever key \(pinnedEndpointHost) presents next. Only do this after a legitimate server rekey, then re-verify with Test.")
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        labeled(label) {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private var privateKeyControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeled("Private key") {
                HStack(spacing: 8) {
                    TextField("None — password or agent only", text: $privateKeyPath)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .font(.system(size: 11, design: .monospaced))
                        .help("Path to an SSH private key, e.g. ~/.ssh/id_ed25519")
                    Button("Choose…") { chooseKey() }
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
                        .help("Remove the private key")
                        .a11yButton("Remove the private key")
                    }
                }
            }
            if !privateKeyPath.isEmpty {
                labeled("Key passphrase") {
                    SecureField(existing?.privateKeyPath == nil ? "leave blank if the key has none"
                                                               : "•••••• (unchanged)",
                                text: $keyPassphrase)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: keyPassphrase) { _, _ in keyPassphraseEdited = true }
                }
                if !FileManager.default.isReadableFile(atPath: expandedKeyPath) {
                    Text("Goel can't read that file — check the path and its permissions.")
                        .font(.system(size: 10)).foregroundStyle(Theme.red)
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
        panel.message = "Choose an SSH private key (for example id_ed25519 — not the .pub file)."
        panel.prompt = "Choose"
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
                Label("Reset pinned host key", systemImage: "key.slash")
                    .scaledFont(size: 11)
            }
            .buttonStyle(.link)
            .help("Forget the saved SSH host-key fingerprint. Use this only after a legitimate server rekey, then re-verify with Test.")
            if hostKeyReset {
                Text("Pinned key cleared — Goel will ask you to confirm the key on the next connection.")
                    .scaledFont(size: 10).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        switch result {
        case .success(let fp):
            VStack(alignment: .leading, spacing: 3) {
                Label("Connected successfully", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.green).scaledFont(size: 12, weight: .semibold)
                Text("Host key SHA-256:").scaledFont(size: 10).foregroundStyle(.secondary)
                    .a11yDecorative()
                Text(fp).scaledFont(size: 10, design: .monospaced)
                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    // Spelled out character by character: base64 read as words cannot be checked against `ssh-keygen -lf`.
                    .accessibilityLabel("Host key SHA-256 fingerprint")
                    .accessibilityValue(fp.map { "\($0) " }.joined())
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connection test succeeded")
        case .failure(let message, let detail, let retry):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Theme.red).scaledFont(size: 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Connection test failed. \(message)")
                if let retry {
                    Button {
                        switch retry {
                        case .test: runTest()
                        case .save: save()
                        }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .scaledFont(size: 11)
                    }
                    .disabled(testing)
                }
                if let detail {
                    DisclosureGroup("Technical detail") {
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 10))
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
            testResult = .failure("Goel couldn’t clear the saved host key for \(pinnedEndpointHost).",
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
                testResult = .failure("Enter a host and username first.", detail: nil)
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
        let outcome = vm.saveServer(draftConnection(),
                                    password: password.isEmpty ? nil : password,
                                    keyPassphrase: keyPassphraseEdited ? keyPassphrase : nil)
        guard outcome.didStore else {
            testResult = .failure(
                outcome.isRetryable
                    ? "The server was saved, but Goel wasn't allowed to store the secret in your Keychain. Choose Allow when macOS asks, then try again."
                    : "The server was saved, but its secret couldn't be written to your Keychain.",
                detail: outcome.statusDetail,
                retry: outcome.isRetryable ? .save : nil)
            return
        }
        vm.toastNow(isNew ? "Server added" : "Server saved")
        dismiss()
    }
}
