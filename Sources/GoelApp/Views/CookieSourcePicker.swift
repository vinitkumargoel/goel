import SwiftUI
import GoelCore

struct CookieSourcePicker: View {

    /// Cookies are scoped to exactly this host and must never be sent to another.
    let host: String?

    @Binding var source: CookieSource

    @Binding var pastedCookies: String

    var capturedCookies: String?

    /// The only output: callers must never read `pastedCookies` instead of this sanitised value.
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

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .a11yDecorative()
            Text(L10n.t("Sign-in cookies"))
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
                    .disabled(option == .browser && capturedCookies == nil)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(L10n.t("Cookie source"))
    }

    /// `SecureField`, never a plain field: a Cookie header is a working credential on any shared screen.
    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("sid=…; csrf=…", text: $pastedCookies)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel(L10n.t("Cookie header"))
                .accessibilityHint(L10n.t("Paste the Cookie request header from your browser's developer tools."))
            Text(L10n.t("In your browser: DevTools ▸ Network ▸ the download request ▸ copy the Cookie request header."))
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
            .a11yGroup(label: names.isEmpty ? L10n.t("Warning") : L10n.t("Cookies attached"),
                       value: summaryText(names: names))
        }
    }

    /// Cookie names only — never render a cookie value here.
    private func summaryText(names: [String]) -> String {
        guard !names.isEmpty else {
            return source == .browser
                ? L10n.t("No cookies were captured with this link. Re-copy it from the browser extension.")
                : L10n.t("Nothing usable pasted yet.")
        }
        let shown = names.prefix(4).joined(separator: ", ")
        let more = names.count > 4 ? L10n.t(" +%d more", names.count - 4) : ""
        let where_ = host.map { L10n.t(" to %@", $0) } ?? ""
        let count = names.count == 1
            ? L10n.t("%d cookie", names.count)
            : L10n.t("%d cookies", names.count)
        return L10n.t("%1$@%2$@ — %3$@%4$@. ", count, where_, shown, more)
            + L10n.t("Kept in memory for this download only: never saved to disk, never written to logs.")
    }
}

#if DEBUG
#Preview("Cookie source") {
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
                    capturedCookies: nil
                )
            }
            .padding(18)
            .frame(width: 420)
        }
    }
    return Harness()
}
#endif
