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
        let approved = await present(endpoint: endpoint, fingerprint: fingerprint)
        let waiting = pending.removeValue(forKey: endpoint) ?? []
        for continuation in waiting { continuation.resume(returning: approved) }
        return approved
    }

    private func present(endpoint: String, fingerprint: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("Is this really %@?", endpoint)
        alert.informativeText = L10n.t("""
            Goel has never connected to this server, so it can't tell whether the \
            machine answering is yours. Compare the fingerprint below with the one \
            the server reports for its own host key, then decide.

            Goel remembers the key you accept and refuses to connect if it changes.
            """)
        alert.addButton(withTitle: L10n.t("Connect and Remember"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        alert.accessoryView = Self.fingerprintView(fingerprint)

        // No window yet: fall back to app-modal rather than skipping the question.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private static func fingerprintView(_ fingerprint: String) -> NSView {
        let field = NSTextField(labelWithString: L10n.t("SHA-256: %@", fingerprint))
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 280
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 46)
        // Spelled out per character: read as words the fingerprint can't be verified by ear.
        field.setAccessibilityLabel(L10n.t("Host key SHA-256 fingerprint"))
        field.setAccessibilityValue(fingerprint.map { "\($0) " }.joined())
        return field
    }
}
