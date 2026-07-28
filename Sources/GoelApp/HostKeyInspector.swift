import AppKit
import GoelCore

@MainActor
enum HostKeyInspector {

    enum LiveKey {
        case read(String)
        case unreachable(String)
    }

    static func present(endpoint: String, pinned: HostKeyStore.PinLookup, live: LiveKey) {
        let alert = NSAlert()
        alert.messageText = L10n.t("Host key for %@", endpoint)
        alert.informativeText = summary(pinned: pinned, live: live)
        alert.alertStyle = isMismatch(pinned: pinned, live: live) ? .critical : .informational
        alert.accessoryView = detailView(pinned: pinned, live: live)
        alert.addButton(withTitle: L10n.t("Done"))
        let copyable = liveFingerprint(live) ?? pinnedFingerprint(pinned)
        if copyable != nil { alert.addButton(withTitle: L10n.t("Copy Fingerprint")) }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            copy(copyable, if: alert.runModal())
            return
        }
        // nonisolated handler: NSPasteboard is not main-actor isolated, so it needs no hop.
        alert.beginSheetModal(for: window) { response in
            Self.copy(copyable, if: response)
        }
    }

    /// Copy is the second button, and only exists when there is something to copy.
    private nonisolated static func copy(_ value: String?, if response: NSApplication.ModalResponse) {
        guard response == .alertSecondButtonReturn, let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private static func pinnedFingerprint(_ pinned: HostKeyStore.PinLookup) -> String? {
        if case .pinned(let fp) = pinned { return fp }
        return nil
    }

    private static func liveFingerprint(_ live: LiveKey) -> String? {
        if case .read(let fp) = live { return fp }
        return nil
    }

    /// Only a readable pin disagreeing with a successful read is a mismatch; unreachable is not.
    static func isMismatch(pinned: HostKeyStore.PinLookup, live: LiveKey) -> Bool {
        guard let pin = pinnedFingerprint(pinned), let now = liveFingerprint(live) else { return false }
        return pin != now
    }

    private static func summary(pinned: HostKeyStore.PinLookup, live: LiveKey) -> String {
        switch (pinned, live) {
        case (.pinned(let pin), .read(let now)) where pin == now:
            return L10n.t("""
                The server is presenting the key Goel pinned. Connections to this \
                server are verified against it.
                """)
        case (.pinned, .read):
            return L10n.t("""
                The key this server is presenting does NOT match the one Goel pinned, \
                so connections are being refused.

                If you rekeyed this server yourself, use “Forget Host Key” and confirm \
                the new key on the next connection. If you did not, do not connect — \
                something is answering in this server’s place.
                """)
        case (.pinned, .unreachable(let reason)):
            return L10n.t("""
                Goel has a key pinned for this server. It couldn’t read the server’s \
                current key to compare: %@
                """, reason)
        case (.none, .read):
            return L10n.t("""
                Goel hasn’t pinned a key for this server yet — it will ask you to \
                confirm the one below the first time it connects. Compare it with the \
                fingerprint the server reports for its own host key.
                """)
        case (.none, .unreachable(let reason)):
            return L10n.t("""
                Goel hasn’t pinned a key for this server yet, and couldn’t read the \
                server’s current key: %@
                """, reason)
        case (.unavailable, _):
            // The store fails closed: this state blocks every connection until the record is cleared.
            return L10n.t("""
                Goel can’t read its record of pinned host keys, so it is refusing to \
                connect to any saved server rather than trusting one it can’t verify. \
                “Forget Host Key” clears the record and restores first-contact \
                approval.
                """)
        }
    }

    private static func detailView(pinned: HostKeyStore.PinLookup, live: LiveKey) -> NSView {
        var lines: [(String, String)] = []
        if let pin = pinnedFingerprint(pinned) { lines.append(("Pinned", pin)) }
        if let now = liveFingerprint(live) { lines.append(("Server now", now)) }
        guard !lines.isEmpty else { return NSView(frame: .zero) }

        let width: CGFloat = 300
        let spacing: CGFloat = 6
        let fields: [NSTextField] = lines.map { caption, fingerprint in
            let field = NSTextField(labelWithString:
                L10n.t("%1$@ — SHA-256:\n%2$@", L10n.t(caption), fingerprint))
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isSelectable = true
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byCharWrapping
            // Required for `fittingSize` below to report the wrapped height, not one long line's.
            field.preferredMaxLayoutWidth = width
            // Spaced per character so the hex is spelled out, not read aloud as words.
            field.setAccessibilityLabel(L10n.t("%@ host key SHA-256 fingerprint", L10n.t(caption)))
            field.setAccessibilityValue(fingerprint.map { "\($0) " }.joined())
            return field
        }

        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        // NSAlert sizes an accessory view from its frame; a guessed height clips the fingerprint.
        let height = fields.reduce(0) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, fields.count - 1)) * spacing
        stack.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 46))
        return stack
    }
}
