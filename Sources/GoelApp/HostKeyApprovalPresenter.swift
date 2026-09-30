import AppKit
import GoelCore

/// TOFU prompt: must resolve before any credential is offered to the server.
@MainActor
final class HostKeyApprovalPresenter: HostKeyApproving {

    static let shared = HostKeyApprovalPresenter()

    /// One prompt per endpoint, else a dropped batch stacks one dialog per file.
    private var pending: [String: [CheckedContinuation<Bool, Never>]] = [:]

    func approveFirstContact(host: String, port: Int, fingerprint: String) async -> Bool {
        let endpoint = port == 22 ? host : "\(host):\(port)"
        if pending[endpoint] != nil {
            return await withCheckedContinuation { pending[endpoint]?.append($0) }
        }
        pending[endpoint] = []
        let approved = await present(host: host, port: port, endpoint: endpoint, fingerprint: fingerprint)
        let waiting = pending.removeValue(forKey: endpoint) ?? []
        for continuation in waiting { continuation.resume(returning: approved) }
        return approved
    }

    private func present(host: String, port: Int, endpoint: String, fingerprint: String) async -> Bool {
        let known = KnownHostsCheck.matchingKeyType(host: host, port: port, fingerprintHex: fingerprint)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("Verify %@ before connecting", endpoint)
        alert.informativeText = L10n.t("""
            Goel° has never connected to this server, so it can't tell whether the \
            machine answering is yours. Compare the fingerprint below with the one \
            the server reports for its own host key, then decide.

            Goel° remembers the key you accept and refuses to connect if it changes.
            """)
        // Cancel first, so a reflexive Return never trusts an unverified key for good.
        alert.addButton(withTitle: L10n.t("Cancel"))
        alert.addButton(withTitle: L10n.t("Connect and Remember"))
        alert.buttons[1].keyEquivalent = ""
        alert.accessoryView = Self.detailView(fingerprint: fingerprint, knownKeyType: known)

        // No window yet: fall back to app-modal rather than skipping the question.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return alert.runModal() == .alertSecondButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn)
            }
        }
    }

    /// Run on the server itself; a check over the same network path could be answered by the impostor.
    static let serverCheckCommand =
        #"for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done"#

    private static func detailView(fingerprint: String, knownKeyType: String?) -> NSView {
        let shown = KnownHostsCheck.openSSHFingerprint(hex: fingerprint) ?? L10n.t("SHA-256: %@", fingerprint)
        let key = label(shown, mono: true)
        // Spelled out per character: read as words the fingerprint can't be verified by ear.
        key.setAccessibilityLabel(L10n.t("Host key SHA-256 fingerprint"))
        key.setAccessibilityValue(shown.map { "\($0) " }.joined())

        let hint = label(L10n.t("Check it on the server:"), mono: false)
        hint.textColor = .secondaryLabelColor
        let command = label(serverCheckCommand, mono: true)
        let copy = NSButton(title: L10n.t("Copy Command"), target: CopyTarget.shared,
                            action: #selector(CopyTarget.copyCommand))
        copy.controlSize = .small
        copy.bezelStyle = .rounded

        var views: [NSView] = [key, hint, command, copy]
        if let knownKeyType {
            let match = label(L10n.t("✓ Matches the %@ key you already trust in ~/.ssh/known_hosts.", knownKeyType),
                              mono: false)
            match.textColor = .systemGreen
            views.append(match)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: stack.fittingSize.height)
        return stack
    }

    private static func label(_ text: String, mono: Bool) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        field.isSelectable = true
        field.lineBreakMode = mono ? .byCharWrapping : .byWordWrapping
        field.preferredMaxLayoutWidth = 300
        return field
    }

    @MainActor
    private final class CopyTarget: NSObject {
        static let shared = CopyTarget()
        @objc func copyCommand() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(HostKeyApprovalPresenter.serverCheckCommand, forType: .string)
        }
    }
}
