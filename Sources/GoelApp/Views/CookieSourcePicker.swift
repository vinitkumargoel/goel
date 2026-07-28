import SwiftUI
import GoelCore

/// Picks where a download's login cookies come from. Pasted text is normalised through
/// ``CookieHeader/sanitized(_:)`` and bound to `host`. Shows cookie **names**, never values.
struct CookieSourcePicker: View {

    /// The host the download will hit; cookies are scoped to exactly this host.
    /// nil for a source with no origin (a magnet), where the control hides.
    let host: String?

    /// The user's choice. `.browser` is only selectable when a capture exists.
    @Binding var source: CookieSource

    /// The raw `Cookie` header the user pasted. Sanitised on the way out via
    /// ``sanitizedCookieHeader``; never written to disk by this view.
    @Binding var pastedCookies: String

    /// The cookie header the browser extension captured with this link, if any.
    /// Presence is what makes `.browser` meaningful.
    var capturedCookies: String?

    /// The normalised value the caller should attach to the task — nil when the user chose `.none`
    /// or pasted nothing usable. The single output; callers must not read `pastedCookies`.
    var sanitizedCookieHeader: String? {
        switch source {
        case .none:    return nil
        case .browser: return capturedCookies.flatMap(CookieHeader.sanitized)
        case .manual:  return CookieHeader.sanitized(pastedCookies)
        }
    }

    var body: some View {
        if host == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                picker
                Text(source.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if source == .manual { pasteField }
                summary
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .a11yDecorative()
            Text("Sign-in cookies")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }

    private var picker: some View {
        Picker("", selection: $source) {
            ForEach(CookieSource.allCases) { option in
                Text(option.displayName)
                    .tag(option)
                    // "From browser" is a promise we can only keep when the
                    // extension actually captured something with this link.
                    .disabled(option == .browser && capturedCookies == nil)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // `labelsHidden()` also strips the name from assistive technology.
        .accessibilityLabel("Cookie source")
    }

    /// `SecureField`, not a text field: a Cookie header on a shared screen or in a screenshot is a
    /// working account credential, so it is masked like a password. One line is enough.
    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("sid=…; csrf=…", text: $pastedCookies)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel("Cookie header")
                .accessibilityHint("Paste the Cookie request header from your browser's developer tools.")
            Text("In your browser: DevTools ▸ Network ▸ the download request ▸ copy the Cookie request header.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if source != .none {
            let names = sanitizedCookieHeader.map(CookieHeader.names(in:)) ?? []
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: names.isEmpty ? "exclamationmark.triangle" : "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(names.isEmpty ? Theme.orange : Theme.green)
                Text(summaryText(names: names))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // Whether cookies were actually picked up is signalled by a swapped
            // glyph and an orange-vs-green tint — both colour-alone cues. Say it.
            .a11yGroup(label: names.isEmpty ? "Warning" : "Cookies attached",
                       value: summaryText(names: names))
        }
    }

    /// Names only, capped — enough to recognise the session, never the secret.
    private func summaryText(names: [String]) -> String {
        guard !names.isEmpty else {
            return source == .browser
                ? "No cookies were captured with this link. Re-copy it from the browser extension."
                : "Nothing usable pasted yet."
        }
        let shown = names.prefix(4).joined(separator: ", ")
        let more = names.count > 4 ? " +\(names.count - 4) more" : ""
        let where_ = host.map { " to \($0)" } ?? ""
        return "\(names.count) cookie\(names.count == 1 ? "" : "s")\(where_) — \(shown)\(more). "
            + "Kept in memory for this download only: never saved to disk, never written to logs."
    }
}

#if DEBUG
#Preview("Cookie source") {
    /// Self-contained harness so the view previews with no app state.
    struct Harness: View {
        @State private var source: CookieSource = .browser
        @State private var pasted = ""
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                CookieSourcePicker(
                    host: "files.example.com",
                    source: $source,
                    pastedCookies: $pasted,
                    capturedCookies: "sid=REDACTED; csrf=REDACTED; theme=dark"
                )
                Divider()
                CookieSourcePicker(
                    host: "files.example.com",
                    source: .constant(.browser),
                    pastedCookies: .constant(""),
                    capturedCookies: nil    // nothing captured — the warning state
                )
            }
            .padding(18)
            .frame(width: 420)
        }
    }
    return Harness()
}
#endif
