import AppKit
import GoelCore

/// Asks the user to confirm a server's identity on first contact, before any credential is offered.
/// `NSAlert`, not a SwiftUI sheet: first contact can happen from inside the connection editor.
@MainActor
final class HostKeyApprovalPresenter: HostKeyApproving {

    static let shared = HostKeyApprovalPresenter()

    /// One prompt per endpoint at a time. A dropped batch opens several sessions that all reach
    /// first contact, which would otherwise stack one dialog per file; later arrivals wait.
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
        alert.messageText = "Is this really \(endpoint)?"
        alert.informativeText = """
            Goel has never connected to this server, so it can't tell whether the \
            machine answering is yours. Compare the fingerprint below with the one \
            the server reports for its own host key, then decide.

            Goel remembers the key you accept and refuses to connect if it changes.
            """
        alert.addButton(withTitle: "Connect and Remember")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.fingerprintView(fingerprint)

        // No window at all (a connection started before the UI is up): fall back
        // to an app-modal alert rather than skipping the question.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    /// The fingerprint as selectable monospaced text. It is the whole point of the prompt, so it has
    /// to be copyable next to the server's own output rather than eyeballed.
    private static func fingerprintView(_ fingerprint: String) -> NSView {
        let field = NSTextField(labelWithString: "SHA-256: \(fingerprint)")
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 280
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 46)
        // Base64/hex read as words is unverifiable; spell it out, which is the
        // only way to compare it against the server's output by ear.
        field.setAccessibilityLabel("Host key SHA-256 fingerprint")
        field.setAccessibilityValue(fingerprint.map { "\($0) " }.joined())
        return field
    }
}
