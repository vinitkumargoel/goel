import SwiftUI
import AppKit
import GoelCore

/// What Test (or a Keychain write on Save) last said.
enum SFTPConnectionTestResult: Equatable {
    case success(fingerprint: String)
    case failure(message: String, detail: String?, retry: Retry?)

    enum Retry: Equatable { case test, save }
}

/// Test, Save and the pinned-host-key reset, plus their result cards.
extension SFTPConnectionEditor {

    // MARK: - Host key

    /// Drops the pinned SSH fingerprint: the next connection trusts whatever key is presented, so this is rekey-only.
    @ViewBuilder
    var hostKeyResetControl: some View {
        if confirmingHostKeyReset {
            VStack(alignment: .leading, spacing: Studio.Space.sm) {
                HStack(alignment: .top, spacing: Studio.Space.sm) {
                    Image(systemName: "key.slash")
                        .font(StudioFonts.font(.ui, size: 13, weight: 650))
                        .foregroundStyle(Studio.Palette.bad)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t("Reset the pinned host key?"))
                            .studioFont(.bodyStrong)
                            .foregroundStyle(Studio.Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.t("Goel° will trust whatever key %@ presents next. Only do this after a legitimate server rekey, then re-verify with Test.", pinnedEndpointHost))
                            .studioFont(.callout.weight(400))
                            .foregroundStyle(Studio.Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: Studio.Space.s) {
                    Spacer()
                    Button(L10n.t("Cancel")) { confirmingHostKeyReset = false }
                        .buttonStyle(.studio(.ghost, size: .small))
                    Button(L10n.t("Reset Key"), role: .destructive) {
                        confirmingHostKeyReset = false
                        resetPinnedHostKey()
                    }
                    .buttonStyle(.studio(.destructivePrimary, size: .small))
                }
            }
            .padding(Studio.Space.m)
            .background(Studio.Palette.badSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                Button(L10n.t("Reset pinned host key"), systemImage: "key.slash") {
                    confirmingHostKeyReset = true
                }
                .buttonStyle(.studio(.ghost, size: .small))
                .help(L10n.t("Forget the saved SSH host-key fingerprint. Use this only after a legitimate server rekey, then re-verify with Test."))
                if hostKeyReset {
                    Text(L10n.t("Pinned key cleared — Goel° will ask you to confirm the key on the next connection."))
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                        .padding(.leading, Studio.Space.sm)
                }
            }
        }
    }

    /// The pin belongs to the saved endpoint, not the draft: host/port may have been edited since.
    var pinnedEndpointHost: String { existing?.host ?? host }
    var pinnedEndpointPort: Int { existing?.port ?? portNumber }

    func resetPinnedHostKey() {
        guard HostKeyStore.shared.reset(host: pinnedEndpointHost, port: pinnedEndpointPort) else {
            testResult = .failure(message: L10n.t("Goel° couldn’t clear the saved host key for %@.", pinnedEndpointHost),
                                  detail: nil, retry: nil)
            return
        }
        testResult = nil
        hostKeyReset = true
        // Pooled connections carry the pin they were built with; without this the live one still demands the old key.
        let endpoint = SFTPTarget(host: pinnedEndpointHost, port: pinnedEndpointPort,
                                  username: existing?.username ?? username, password: nil)
        Task { await SFTPSessionPool.shared.disconnectAll(matching: endpoint) }
    }

    // MARK: - Result card

    @ViewBuilder
    func testResultView(_ result: SFTPConnectionTestResult) -> some View {
        switch result {
        case .success(let fingerprint):
            SFTPTestSuccessCard(fingerprint: fingerprint)
        case .failure(let message, let detail, let retry):
            SFTPTestFailureCard(message: message, detail: detail,
                                retryEnabled: !testing,
                                onRetry: retry.map { kind in
                                    { kind == .test ? runTest() : save() }
                                })
        }
    }

    // MARK: - Test

    func draftConnection() -> SFTPConnection {
        // libssh2 opens the key with plain fopen(), so a literal "~/.ssh/id_ed25519" would never resolve.
        let key = privateKeyPath.trimmingCharacters(in: .whitespaces)
        return SFTPConnection(id: existing?.id ?? UUID(),
                              name: name, host: host, port: portNumber,
                              username: username,
                              initialPath: initialPath.isEmpty ? "." : initialPath,
                              useAgent: useAgent,
                              privateKeyPath: key.isEmpty ? nil : (key as NSString).expandingTildeInPath)
    }

    func runTest() {
        testing = true
        testResult = nil
        let connection = draftConnection()
        // Deliberately does not pre-fetch the stored secret — that meant two Keychain prompts per Test.
        let pw: String? = password.isEmpty ? nil : password
        let phrase: String? = keyPassphraseEdited ? keyPassphrase : nil
        Task {
            // Explicit `password:` avoids re-pulling a stale secret; `credentialIdentity:` because secrets are keyed by user@host:port, which may have been edited.
            let client: SFTPClient
            switch SFTPSession.resolve(for: connection, password: pw, keyPassphrase: phrase,
                                       credentialIdentity: existing) {
            case .ready(let c):
                client = c
            case .incomplete:
                testing = false
                testResult = .failure(message: L10n.t("Enter a host and username first."), detail: nil, retry: nil)
                return
            case .credentialsUnavailable(let lookup):
                let e = SFTPError.credentialsUnavailable(lookup, host: connection.host)
                testing = false
                testResult = .failure(message: e.message, detail: e.detail,
                                      retry: lookup.isRetryable ? .test : nil)
                return
            }
            do {
                let fingerprint = try await client.probe()
                testing = false
                testResult = .success(fingerprint: fingerprint)
            } catch let e as SFTPError {
                testing = false
                testResult = .failure(message: e.message, detail: e.detail,
                                      retry: e.kind == .credentialsUnavailable ? .test : nil)
            } catch {
                testing = false
                testResult = .failure(message: error.localizedDescription, detail: nil, retry: nil)
            }
        }
    }

    // MARK: - Save

    func save() {
        let isNew = existing == nil
        let result = vm.saveServer(draftConnection(),
                                   password: password.isEmpty ? nil : password,
                                   keyPassphrase: keyPassphraseEdited ? keyPassphrase : nil)
        // The profile never reached disk; the view model already said why, so don't
        // follow it with Keychain copy that implies the server was saved.
        guard case .saved(let outcome) = result else { return }
        guard outcome.didStore else {
            testResult = .failure(
                message: outcome.isRetryable
                    ? L10n.t("The server was saved, but Goel° wasn’t allowed to store the secret in your Keychain. Choose Allow when macOS asks, then try again.")
                    : L10n.t("The server was saved, but its secret couldn’t be written to your Keychain."),
                detail: outcome.statusDetail,
                retry: outcome.isRetryable ? .save : nil)
            return
        }
        vm.toastNow(isNew ? L10n.t("Server added") : L10n.t("Server saved"))
        dismiss()
    }
}

/// "Connected successfully" with the host key's SHA-256, spelled out for VoiceOver.
struct SFTPTestSuccessCard: View {
    let fingerprint: String

    var body: some View {
        HStack(alignment: .top, spacing: Studio.Space.sm) {
            Image(systemName: "checkmark.shield.fill")
                .font(StudioFonts.font(.ui, size: 14, weight: 650))
                .foregroundStyle(Studio.Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("Connected successfully"))
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                Text(L10n.t("Host key SHA-256:"))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink2)
                    .a11yDecorative()
                Text(fingerprint)
                    .studioFont(.monoSmall)
                    .foregroundStyle(Studio.Palette.ink)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // Spelled out character by character: base64 read as words cannot be checked against `ssh-keygen -lf`.
                    .accessibilityLabel(L10n.t("Host key SHA-256 fingerprint"))
                    .accessibilityValue(fingerprint.map { "\($0) " }.joined())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, Studio.Space.sm)
        .background(Studio.Palette.accentSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Connection test succeeded"))
    }
}

/// A failed test or Keychain write: the reason, Try again when it can help, and the raw detail.
struct SFTPTestFailureCard: View {
    let message: String
    let detail: String?
    var retryEnabled = true
    var onRetry: (() -> Void)?

    @State private var showsDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: Studio.Space.sm) {
            Image(systemName: "xmark.octagon.fill")
                .font(StudioFonts.font(.ui, size: 14, weight: 650))
                .foregroundStyle(Studio.Palette.bad)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                Text(message)
                    .studioFont(.callout.weight(500))
                    .foregroundStyle(Studio.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L10n.t("Connection test failed. %@", message))
                HStack(spacing: Studio.Space.xs) {
                    if let onRetry {
                        Button(L10n.t("Try again"), systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(.studio(.secondary, size: .small))
                            .disabled(!retryEnabled)
                    }
                    if detail != nil {
                        Button(L10n.t("Technical detail"),
                               systemImage: showsDetail ? "chevron.down" : "chevron.right") {
                            showsDetail.toggle()
                        }
                        .buttonStyle(.studio(.ghost, size: .small))
                        .accessibilityValue(showsDetail ? L10n.t("Expanded") : L10n.t("Collapsed"))
                    }
                }
                if showsDetail, let detail {
                    Text(detail)
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, Studio.Space.sm)
        .background(Studio.Palette.badSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
    }
}

/// A form label over its control; required fields say so to VoiceOver.
struct SFTPLabeledField<Content: View>: View {
    let label: String
    var required = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(required ? L10n.t("%@ *", label) : label)
                .studioFont(.callout.weight(650).size(12))
                .foregroundStyle(Studio.Palette.ink2)
                .accessibilityLabel(required ? L10n.t("%@, required", label) : label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A one-line note under a field (`.help`), red when it is a problem.
struct SFTPFieldMessage: View {
    let text: String
    var tone: StudioTone = .neutral

    var body: some View {
        Text(text)
            .studioFont(.caption)
            .foregroundStyle(tone == .neutral ? Studio.Palette.ink3 : tone.foreground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Import from ~/.ssh/config": every Host entry, or a note that there are none.
struct SFTPSSHConfigMenu: View {
    let hosts: [SFTPAddress]
    let onPick: (SFTPAddress) -> Void

    var body: some View {
        Menu {
            if hosts.isEmpty {
                Text(L10n.t("No hosts in ~/.ssh/config"))
            }
            ForEach(hosts, id: \.alias) { entry in
                Button(entry.alias == entry.host ? entry.host
                                                 : L10n.t("%@ — %@", entry.alias ?? entry.host, entry.host)) {
                    onPick(entry)
                }
            }
        } label: {
            Label(L10n.t("~/.ssh/config"), systemImage: "terminal")
                .studioFont(.control.size(12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, Studio.Space.sm)
        .frame(height: 30)
        .background(Studio.Palette.card, in: RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
            .strokeBorder(Studio.Palette.hairlineStrong, lineWidth: 1))
        .help(L10n.t("Import a Host entry from ~/.ssh/config"))
    }
}
