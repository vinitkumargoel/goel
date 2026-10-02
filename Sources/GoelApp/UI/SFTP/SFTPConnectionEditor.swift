import SwiftUI
import AppKit
import GoelCore

/// Add or edit an SFTP server: paste an address (or import a `~/.ssh/config` host) to fill the
/// form, then name, host, port, user, password, key and passphrase, start folder and the SSH
/// agent. Test connects with the draft and shows the host key's SHA-256; Save stores the profile
/// and its secrets in the Keychain. Presented by RootView as a sheet.
struct SFTPConnectionEditor: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) var dismiss

    let existing: SFTPConnection?

    @State var name: String
    @State var host: String
    @State var port: String
    @State var username: String
    @State var password: String
    @State var initialPath: String
    @State var useAgent: Bool
    @State var privateKeyPath: String
    @State var keyPassphrase: String
    /// An untouched passphrase field means "keep the stored passphrase", not "clear it".
    @State var keyPassphraseEdited = false

    @State var pastedAddress = ""
    @State var addressFilled = false
    @State var sshHosts: [SFTPAddress] = []

    @State var testing = false
    @State var testResult: SFTPConnectionTestResult?
    @State var hostKeyReset = false
    /// Asked inline: the window's confirm card is an overlay on RootView, which this sheet would hide.
    @State var confirmingHostKeyReset = false

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

    var portNumber: Int {
        guard let n = Int(port), (1...65535).contains(n) else { return 22 }
        return n
    }
    /// Guards Save/Test so invalid text is never silently coerced to 22 behind the user's back.
    var portIsValid: Bool {
        guard let n = Int(port) else { return false }
        return (1...65535).contains(n)
    }
    var saveBlocker: String? {
        SFTPConnectionForm.saveBlocker(host: host, username: username, portIsValid: portIsValid)
    }
    var canSave: Bool { saveBlocker == nil }

    var body: some View {
        StudioSheet(title: existing == nil ? L10n.t("Add SFTP Server") : L10n.t("Edit SFTP Server"),
                    subtitle: existing.map { $0.credentialKey },
                    symbol: "server.rack", width: 520) {
            form
        } footer: {
            StudioSheetFooter(onCancel: { dismiss() }, primaryTitle: L10n.t("Save"),
                              primaryEnabled: canSave, onPrimary: save) {
                testButton
            }
        }
        .onAppear { if existing == nil { sshHosts = SSHConfigImport.load() } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            if existing == nil { quickFillRow }
            SFTPLabeledField(label: L10n.t("Name")) {
                TextField(L10n.t("My Server (optional)"), text: $name)
                    .textFieldStyle(.studio(size: .small))
                    .autocorrectionDisabled()
            }
            HStack(alignment: .top, spacing: Studio.Space.sm) {
                SFTPLabeledField(label: L10n.t("Host"), required: true) {
                    TextField("example.com", text: $host)
                        .textFieldStyle(.studio(size: .small))
                        .studioFont(.monoBody)
                        .autocorrectionDisabled()
                }
                SFTPLabeledField(label: L10n.t("Port")) {
                    TextField("22", text: $port)
                        .textFieldStyle(.studio(size: .small))
                        .studioFont(.monoBody)
                }
                .frame(width: 90)
            }
            if !portIsValid {
                SFTPFieldMessage(text: L10n.t("Port must be a number between 1 and 65535."), tone: .bad)
            }
            HStack(alignment: .top, spacing: Studio.Space.sm) {
                SFTPLabeledField(label: L10n.t("Username"), required: true) {
                    TextField(L10n.t("user"), text: $username)
                        .textFieldStyle(.studio(size: .small))
                        .autocorrectionDisabled()
                }
                SFTPLabeledField(label: L10n.t("Password")) {
                    SecureField(existing == nil ? L10n.t("password") : L10n.t("•••••• (unchanged)"), text: $password)
                        .textFieldStyle(.studio(size: .small))
                }
            }
            privateKeyControls
            SFTPLabeledField(label: L10n.t("Start folder")) {
                TextField(".", text: $initialPath)
                    .textFieldStyle(.studio(size: .small))
                    .studioFont(.monoBody)
                    .autocorrectionDisabled()
            }
            Toggle(L10n.t("Also try the SSH agent"), isOn: $useAgent)
                .toggleStyle(.studioSwitch)
                .studioFont(.body)
                .foregroundStyle(Studio.Palette.ink)
            if existing != nil { hostKeyResetControl }
            if let result = testResult { testResultView(result) }
            if let saveBlocker {
                SFTPFieldMessage(text: saveBlocker, tone: .neutral)
                    .accessibilityLabel(L10n.t("Save is unavailable. %@", saveBlocker))
            }
        }
    }

    private var testButton: some View {
        HStack(spacing: Studio.Space.s) {
            Button(testResult == nil ? L10n.t("Test") : L10n.t("Test again"), systemImage: "bolt.horizontal.circle") {
                runTest()
            }
            .buttonStyle(.studio(.ghost))
            .disabled(!canSave || testing)
            .help(saveBlocker ?? L10n.t("Try to connect with these settings"))
            if testing {
                ProgressView().controlSize(.small).tint(Studio.Palette.accent)
                    .accessibilityLabel(L10n.t("Testing…"))
            }
        }
    }

    // MARK: - Quick fill

    /// "Paste an address" plus an `~/.ssh/config` import, so a new server rarely needs typing.
    private var quickFillRow: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            HStack(spacing: Studio.Space.s) {
                StudioFocusedField { focus in
                    HStack(spacing: Studio.Space.s) {
                        Image(systemName: "link")
                            .font(StudioFonts.font(.ui, size: 12, weight: 650))
                            .foregroundStyle(Studio.Palette.accent)
                            .accessibilityHidden(true)
                        TextField(L10n.t("Paste an address — sftp://user@host:22/path"), text: $pastedAddress)
                            .textFieldStyle(.plain)
                            .studioFont(.monoSmall)
                            .focused(focus)
                            .autocorrectionDisabled()
                            .onChange(of: pastedAddress) { _, new in fill(from: SFTPAddress.parse(new)) }
                            .accessibilityLabel(L10n.t("Server address to fill the fields from"))
                    }
                }
                SFTPSSHConfigMenu(hosts: sshHosts) { fill(from: $0) }
            }
            if addressFilled {
                Label(L10n.t("Filled from the address"), systemImage: "checkmark.circle.fill")
                    .studioFont(.caption.weight(600))
                    .foregroundStyle(Studio.Palette.good)
            } else {
                Text(L10n.t("Paste an address and the fields below fill in."))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
            }
        }
    }

    func fill(from address: SFTPAddress?) {
        guard let address else { addressFilled = false; return }
        host = address.host
        if let port = address.port { self.port = String(port) }
        if let user = address.username { username = user }
        if let path = address.path { initialPath = path }
        if let alias = address.alias, name.isEmpty { name = alias }
        if let key = address.identityFile { privateKeyPath = key }
        testResult = nil
        addressFilled = true
    }

    // MARK: - Key

    @ViewBuilder
    private var privateKeyControls: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            HStack(alignment: .top, spacing: Studio.Space.sm) {
                SFTPLabeledField(label: L10n.t("Private key")) {
                    HStack(spacing: Studio.Space.xs) {
                        TextField(L10n.t("None — password or agent only"), text: $privateKeyPath)
                            .textFieldStyle(.studio(size: .small))
                            .studioFont(.monoBody)
                            .autocorrectionDisabled()
                            .help(L10n.t("Path to an SSH private key, e.g. ~/.ssh/id_ed25519"))
                        Button(L10n.t("Choose…")) { chooseKey() }
                            .buttonStyle(.studio(.secondary, size: .small))
                            .fixedSize()
                        if !privateKeyPath.isEmpty {
                            StudioIconButton("xmark.circle.fill", label: L10n.t("Remove the private key"),
                                             size: .small) {
                                privateKeyPath = ""
                                keyPassphrase = ""
                                keyPassphraseEdited = true
                            }
                        }
                    }
                }
                if !privateKeyPath.isEmpty {
                    SFTPLabeledField(label: L10n.t("Key passphrase")) {
                        SecureField(existing?.privateKeyPath == nil ? L10n.t("leave blank if the key has none")
                                                                   : L10n.t("•••••• (unchanged)"),
                                    text: $keyPassphrase)
                            .textFieldStyle(.studio(size: .small))
                            .onChange(of: keyPassphrase) { _, _ in keyPassphraseEdited = true }
                    }
                    .frame(width: 170)
                }
            }
            if !privateKeyPath.isEmpty, !FileManager.default.isReadableFile(atPath: expandedKeyPath) {
                SFTPFieldMessage(text: L10n.t("Goel° can’t read that file — check the path and its permissions."),
                                 tone: .bad)
            }
        }
    }

    /// libssh2 does no tilde expansion, so `~` must be resolved before it or the readability check sees the path.
    var expandedKeyPath: String {
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
}

#if DEBUG
/// A filled-in form for a snapshot: the fields, a pasted address and a test result.
struct SFTPConnectionEditorPreview {
    var address = ""
    var name = ""
    var host = ""
    var port = "22"
    var username = ""
    var initialPath = "."
    var useAgent = false
    var privateKeyPath = ""
    var keyPassphrase = ""
    var addressFilled = false
    var testResult: SFTPConnectionTestResult?
    var confirmingHostKeyReset = false
}

extension SFTPConnectionEditor {
    init(existing: SFTPConnection?, preview: SFTPConnectionEditorPreview) {
        self.init(existing: existing)
        _pastedAddress = State(initialValue: preview.address)
        _name = State(initialValue: preview.name)
        _host = State(initialValue: preview.host)
        _port = State(initialValue: preview.port)
        _username = State(initialValue: preview.username)
        _initialPath = State(initialValue: preview.initialPath)
        _useAgent = State(initialValue: preview.useAgent)
        _privateKeyPath = State(initialValue: preview.privateKeyPath)
        _keyPassphrase = State(initialValue: preview.keyPassphrase)
        _addressFilled = State(initialValue: preview.addressFilled)
        _testResult = State(initialValue: preview.testResult)
        _confirmingHostKeyReset = State(initialValue: preview.confirmingHostKeyReset)
    }
}
#endif
