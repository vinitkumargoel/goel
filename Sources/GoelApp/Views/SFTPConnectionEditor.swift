import SwiftUI
import GoelCore

/// Add / edit an SFTP server. Passwords go straight to the Keychain; leaving
/// the field blank when editing keeps the stored one. "Test" connects and shows
/// the server's host-key fingerprint so the user can confirm it's the right box.
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

    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var hostKeyReset = false

    private enum TestResult { case success(String), failure(String) }

    init(existing: SFTPConnection?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: existing?.host ?? "")
        _port = State(initialValue: String(existing?.port ?? 22))
        _username = State(initialValue: existing?.username ?? "")
        _password = State(initialValue: "")
        _initialPath = State(initialValue: existing?.initialPath ?? ".")
        _useAgent = State(initialValue: existing?.useAgent ?? false)
    }

    private var portNumber: Int {
        guard let n = Int(port), (1...65535).contains(n) else { return 22 }
        return n
    }
    /// Whether the Port field holds a valid 1–65535 integer. Guards Save/Test so
    /// invalid text is never silently coerced to 22 behind the user's back.
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

    /// Forget the pinned SSH fingerprint so trust-on-first-use re-learns it —
    /// the in-app recovery after a legitimate server rekey (the pin otherwise
    /// fails closed and permanently blocks the connection).
    @ViewBuilder
    private var hostKeyResetControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                vm.requestConfirm(
                    title: "Reset the pinned host key?",
                    message: "Goel will trust whatever key this server presents next. Only do this after a legitimate server rekey, then re-verify with Test.",
                    confirmTitle: "Reset Key",
                    destructive: true
                ) {
                    HostKeyStore.shared.reset(host: host, port: portNumber)
                    testResult = nil
                    hostKeyReset = true
                }
            } label: {
                Label("Reset pinned host key", systemImage: "key.slash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
            .help("Forget the saved SSH host-key fingerprint. Use this only after a legitimate server rekey, then re-verify with Test.")
            if hostKeyReset {
                Text("Pinned key cleared — it will be re-learned on the next connection.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        switch result {
        case .success(let fp):
            VStack(alignment: .leading, spacing: 3) {
                Label("Connected successfully", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.green).font(.system(size: 12, weight: .semibold))
                Text("Host key SHA-256:").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(fp).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.red).font(.system(size: 12))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Actions

    private func draftConnection() -> SFTPConnection {
        SFTPConnection(id: existing?.id ?? UUID(),
                       name: name, host: host, port: portNumber,
                       username: username,
                       initialPath: initialPath.isEmpty ? "." : initialPath,
                       useAgent: useAgent)
    }

    /// Password to test with: the just-typed one, or the stored one when editing.
    private func testPassword() -> String? {
        if !password.isEmpty { return password }
        if let existing { return SFTPConnectionStore.shared.password(for: existing) }
        return nil
    }

    private func runTest() {
        testing = true
        testResult = nil
        let connection = draftConnection()
        let pw = testPassword()
        Task {
            guard let target = SFTPTarget(connection: connection, password: pw) else {
                testing = false
                testResult = .failure("Enter a host and username first.")
                return
            }
            do {
                let fingerprint = try await SFTPClient(target: target).probe()
                testing = false
                testResult = .success(fingerprint)
            } catch let e as SFTPError {
                testing = false
                testResult = .failure(e.message)
            } catch {
                testing = false
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        // nil password = keep the existing secret; a typed one replaces it.
        let isNew = existing == nil
        vm.saveServer(draftConnection(), password: password.isEmpty ? nil : password)
        vm.toastNow(isNew ? "Server added" : "Server saved")
        dismiss()
    }
}
