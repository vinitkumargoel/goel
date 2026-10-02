import SwiftUI
import GoelCore

/// Where a download's sign-in cookies come from: none, the browser extension's capture, or a
/// pasted Cookie header. Also hosted by the Attach Cookies recovery sheet.
struct CookieSourcePicker: View {

    /// Cookies are scoped to exactly this host and must never be sent to another.
    let host: String?

    @Binding var source: CookieSource

    @Binding var pastedCookies: String

    var capturedCookies: String?

    /// The add sheet's advanced grid draws "Sign-in cookies" in its own label column.
    var showsHeader = true

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
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                if showsHeader { header }
                picker
                AddHelpText(source.explanation)
                if source == .manual { pasteField }
                summary
            }
        }
    }

    private var header: some View {
        HStack(spacing: Studio.Space.xs) {
            Image(systemName: "person.badge.key")
                .font(StudioFonts.font(.ui, size: 12, weight: 650))
                .foregroundStyle(Studio.Palette.accent)
                .a11yDecorative()
            AddFieldLabel(L10n.t("Sign-in cookies"))
            Spacer(minLength: 0)
        }
    }

    private var picker: some View {
        AddSegmentPicker(
            selection: $source,
            options: CookieSource.allCases.map { option in
                .init(value: option, title: option.displayName,
                      isEnabled: !(option == .browser && capturedCookies == nil))
            },
            accessibilityLabel: L10n.t("Cookie source"))
    }

    /// `SecureField`, never a plain field: a Cookie header is a working credential on any shared screen.
    private var pasteField: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xxs) {
            StudioFocusedField(size: .small) { focus in
                SecureField(String("sid=…; csrf=…"), text: $pastedCookies)
                    .textFieldStyle(.plain)
                    .studioFont(.monoBody)
                    .focused(focus)
                    .accessibilityLabel(L10n.t("Cookie header"))
                    .accessibilityHint(L10n.t("Paste the Cookie request header from your browser’s developer tools."))
            }
            AddHelpText(L10n.t("In your browser: DevTools ▸ Network ▸ the download request ▸ copy the Cookie request header."))
        }
    }

    @ViewBuilder
    private var summary: some View {
        if source != .none {
            let names = sanitizedCookieHeader.map(CookieHeader.names(in:)) ?? []
            HStack(alignment: .top, spacing: Studio.Space.xs) {
                Image(systemName: names.isEmpty ? "exclamationmark.triangle.fill" : "lock.fill")
                    .font(StudioFonts.font(.ui, size: 11, weight: 650))
                    .foregroundStyle(names.isEmpty ? Studio.Palette.warn : Studio.Palette.good)
                Text(summaryText(names: names))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Studio.Space.sm)
            .padding(.vertical, Studio.Space.s)
            .background(names.isEmpty ? Studio.Palette.warnSoft : Studio.Palette.goodSoft,
                        in: RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous))
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
        let shownNames = names.prefix(4).joined(separator: ", ")
        let list = names.count > 4
            ? L10n.t("%1$@ and %2$d more", shownNames, names.count - 4)
            : shownNames
        let count = names.count == 1
            ? L10n.t("%d cookie", names.count)
            : L10n.t("%d cookies", names.count)
        let summary = host.map { L10n.t("%1$@ for %2$@: %3$@.", count, $0, list) }
            ?? L10n.t("%1$@: %2$@.", count, list)
        return summary + " "
            + L10n.t("Kept in memory for this download only: never saved to disk, never written to logs.")
    }
}
