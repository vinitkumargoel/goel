import AppKit
import GoelCore

/// Shows what Goel has pinned for a server against the key that server is
/// presenting *right now*.
///
/// The connection editor already displays a fingerprint, but only as the byproduct
/// of a successful "Test" — which needs credentials and a server that will let you
/// in. The question this answers is the one you ask when it *won't* let you in:
/// has the key changed? So the live read here is deliberately credential-free
/// (``SFTPClient/hostKeyFingerprint()`` / `gsb_hostkey` hangs up before offering a
/// password), and an unreachable server still shows the pin.
///
/// `NSAlert` rather than a SwiftUI sheet, for the reason recorded on
/// ``HostKeyApprovalPresenter``: SwiftUI presentation is bound to a view
/// hierarchy, so anything raised from `RootView` is drawn behind a sheet that is
/// already open. An alert attached to the frontmost window always appears above it.
@MainActor
enum HostKeyInspector {

    /// The live read's outcome. `unreachable` carries the reason so a firewalled
    /// host doesn't read as a key mismatch.
    enum LiveKey {
        case read(String)
        case unreachable(String)
    }

    static func present(endpoint: String, pinned: HostKeyStore.PinLookup, live: LiveKey) {
        let alert = NSAlert()
        alert.messageText = "Host key for \(endpoint)"
        alert.informativeText = summary(pinned: pinned, live: live)
        alert.alertStyle = isMismatch(pinned: pinned, live: live) ? .critical : .informational
        alert.accessoryView = detailView(pinned: pinned, live: live)
        alert.addButton(withTitle: "Done")
        // Copying the *live* key is what lets the user paste it next to the
        // server's own `ssh-keygen -lf` output; falling back to the pin keeps the
        // button useful when the server can't be reached.
        let copyable = liveFingerprint(live) ?? pinnedFingerprint(pinned)
        if copyable != nil { alert.addButton(withTitle: "Copy Fingerprint") }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            copy(copyable, if: alert.runModal())
            return
        }
        // The dialog outlives this call, so the value to copy is captured rather
        // than looked up again on dismissal. `NSPasteboard` is not main-actor
        // isolated, so the completion handler needs no hop.
        alert.beginSheetModal(for: window) { response in
            Self.copy(copyable, if: response)
        }
    }

    /// Put the fingerprint on the pasteboard, but only for the Copy button —
    /// which is the second one, and only exists when there is something to copy.
    private nonisolated static func copy(_ value: String?, if response: NSApplication.ModalResponse) {
        guard response == .alertSecondButtonReturn, let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: Wording

    private static func pinnedFingerprint(_ pinned: HostKeyStore.PinLookup) -> String? {
        if case .pinned(let fp) = pinned { return fp }
        return nil
    }

    private static func liveFingerprint(_ live: LiveKey) -> String? {
        if case .read(let fp) = live { return fp }
        return nil
    }

    /// Only a *readable* pin that disagrees with a *successful* read is a
    /// mismatch. Everything else is missing information, not evidence — and this
    /// decides whether the user sees a critical "something is answering in this
    /// server's place" alert, so a firewalled host or an unreadable pin record
    /// must not be able to raise one.
    static func isMismatch(pinned: HostKeyStore.PinLookup, live: LiveKey) -> Bool {
        guard let pin = pinnedFingerprint(pinned), let now = liveFingerprint(live) else { return false }
        return pin != now
    }

    private static func summary(pinned: HostKeyStore.PinLookup, live: LiveKey) -> String {
        switch (pinned, live) {
        case (.pinned(let pin), .read(let now)) where pin == now:
            return """
                The server is presenting the key Goel pinned. Connections to this \
                server are verified against it.
                """
        case (.pinned, .read):
            return """
                The key this server is presenting does NOT match the one Goel pinned, \
                so connections are being refused.

                If you rekeyed this server yourself, use “Forget Host Key” and confirm \
                the new key on the next connection. If you did not, do not connect — \
                something is answering in this server’s place.
                """
        case (.pinned, .unreachable(let reason)):
            return """
                Goel has a key pinned for this server. It couldn’t read the server’s \
                current key to compare: \(reason)
                """
        case (.none, .read):
            return """
                Goel hasn’t pinned a key for this server yet — it will ask you to \
                confirm the one below the first time it connects. Compare it with the \
                fingerprint the server reports for its own host key.
                """
        case (.none, .unreachable(let reason)):
            return """
                Goel hasn’t pinned a key for this server yet, and couldn’t read the \
                server’s current key: \(reason)
                """
        case (.unavailable, _):
            // The store fails closed, so this state blocks every connection to
            // every server until the record is cleared.
            return """
                Goel can’t read its record of pinned host keys, so it is refusing to \
                connect to any saved server rather than trusting one it can’t verify. \
                “Forget Host Key” clears the record and restores first-contact \
                approval.
                """
        }
    }

    // MARK: Accessory

    /// The fingerprints as selectable monospaced text — the whole point of the
    /// dialog is comparing them against the server's own output, which means they
    /// have to be copyable rather than eyeballed.
    private static func detailView(pinned: HostKeyStore.PinLookup, live: LiveKey) -> NSView {
        var lines: [(String, String)] = []
        if let pin = pinnedFingerprint(pinned) { lines.append(("Pinned", pin)) }
        if let now = liveFingerprint(live) { lines.append(("Server now", now)) }
        guard !lines.isEmpty else { return NSView(frame: .zero) }

        let width: CGFloat = 300
        let spacing: CGFloat = 6
        let fields: [NSTextField] = lines.map { caption, fingerprint in
            let field = NSTextField(labelWithString: "\(caption) — SHA-256:\n\(fingerprint)")
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isSelectable = true
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byCharWrapping
            // Wraps the 64 hex characters, and makes `fittingSize` below report
            // the wrapped height rather than one long line's.
            field.preferredMaxLayoutWidth = width
            // Hex read as words is unverifiable; spell it out, which is the only
            // way to compare it against the server's output by ear.
            field.setAccessibilityLabel("\(caption) host key SHA-256 fingerprint")
            field.setAccessibilityValue(fingerprint.map { "\($0) " }.joined())
            return field
        }

        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        // `NSAlert` sizes an accessory view from its frame, so the height is
        // measured rather than guessed: a hard-coded box that comes up short
        // clips the fingerprint, and half a fingerprint is worse than none — it
        // is exactly the part the user is meant to compare character by
        // character. Summed from the labels' own fitting sizes, which avoids
        // adding a width constraint to a view whose frame is set directly.
        let height = fields.reduce(0) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, fields.count - 1)) * spacing
        stack.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 46))
        return stack
    }
}
