import SwiftUI
import GoelCore

/// Web Access › Hardening: HTTPS, host names, sign-in backoff and SSO, folded into one card that
/// opens on demand (and by itself when the search hits one of its rows).
struct WebAccessHardeningCard: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var isExpanded: Bool
    /// Committed on Return / focus loss: `validated()` would eat a half-typed `goel.` or `https:` per keystroke.
    @State private var hostNamesDraft: String?
    @Environment(\.settingsSearchQuery) private var searchQuery
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rowTitles = [
        "Hardening", "Serve over HTTPS", "Identity (.p12) path", "Extra host names",
        "Failed sign-ins before backoff", "Backoff (seconds)", "Single sign-on (advanced)",
        "Trust a proxy’s identity header", "Header name", "Trusted proxies",
    ]

    private var searchOpensIt: Bool {
        Self.rowTitles.contains { SettingsSearch.highlights(L10n.t($0), query: searchQuery)
            || SettingsSearch.highlights($0, query: searchQuery) }
    }

    private var showsRows: Bool { isExpanded || searchOpensIt }

    var body: some View {
        SettingsCard {
            header
            if showsRows {
                hardeningRows
                ssoRows
            }
        }
    }

    private var header: some View {
        Button {
            if reduceMotion { isExpanded.toggle() } else {
                withAnimation(Studio.Motion.quick) { isExpanded.toggle() }
            }
        } label: {
            HStack(spacing: Studio.Space.m) {
                Image(systemName: "lock.shield")
                    .studioFont(.ui, size: 15, weight: 650)
                    .foregroundStyle(Studio.Palette.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    Text(L10n.t("Hardening"))
                        .studioFont(.title3)
                        .foregroundStyle(Studio.Palette.ink)
                    Text(L10n.t("HTTPS certificate (.p12), extra host names, sign-in backoff, SSO header"))
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Studio.Space.s)
                Image(systemName: "chevron.right")
                    .studioFont(.ui, size: 12, weight: 700)
                    .foregroundStyle(Studio.Palette.ink3)
                    .rotationEffect(.degrees(showsRows ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, Studio.Space.ml)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("Hardening"))
        .accessibilityValue(showsRows ? L10n.t("Expanded") : L10n.t("Collapsed"))
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var hardeningRows: some View {
        SettingRow(L10n.t("Serve over HTTPS"),
                   detail: L10n.t("Encrypt the portal with a PKCS#12 identity. If the identity can’t be loaded "
                       + "the server refuses to start rather than falling back to cleartext.")) {
            SettingSwitch(isOn: setting(vm, \.remoteTLSEnabled))
                .managed(.remoteTLSEnabled, vm.managedPolicy)
        }
        if vm.settings.remoteTLSEnabled {
            SettingRow(L10n.t("Identity (.p12) path"),
                       detail: L10n.t("Its passphrase is read from the GOEL_PORTAL_TLS_PASSPHRASE "
                           + "environment variable — Goel° never stores it."),
                       isIndented: true) {
                SettingsTextField(text: setting(vm, \.remoteTLSIdentityPath), width: 180,
                                  placeholder: L10n.t("/path/to/identity.p12"), isMonospaced: true)
                    .managed(.remoteTLSIdentityPath, vm.managedPolicy)
            }
        }
        SettingRow(L10n.t("Extra host names"),
                   detail: L10n.t("Extra host names (comma-separated), e.g. goel.home, mymac.tailnet.ts.net. The "
                       + "portal answers only to IP addresses, localhost and .local names unless a name is listed "
                       + "here.")) {
            StudioFocusedField(size: .small) { focus in
                ZStack(alignment: .leading) {
                    if allowedHostNamesBinding.wrappedValue.isEmpty {
                        Text(L10n.t("goel.home"))
                            .foregroundStyle(Studio.Palette.ink3)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: allowedHostNamesBinding)
                        .textFieldStyle(.plain)
                        .focused(focus)
                        .onSubmit(commitHostNames)
                        .onChange(of: focus.wrappedValue) { _, focused in
                            if !focused { commitHostNames() }
                        }
                }
                .studioFont(.monoBody)
            }
            .frame(width: 180)
            .accessibilityLabel(L10n.t("Extra host names"))
            .onDisappear(perform: commitHostNames)
            .managed(.remoteAllowedHostNames, vm.managedPolicy)
        }
        SettingRow(L10n.t("Failed sign-ins before backoff"),
                   detail: L10n.t("Wrong passwords from one address are slowed exponentially. The delay "
                       + "is per-address, so one attacker can’t lock everybody else out.")) {
            SettingsIntField(value: setting(vm, \.remoteLoginMaxAttempts), width: 80)
        }
        SettingRow(L10n.t("Backoff (seconds)"),
                   detail: L10n.t("The first delay after the limit is hit; it doubles from there.")) {
            SettingsIntField(value: backoffSecondsBinding, unit: L10n.t("s"), width: 80)
        }
    }

    @ViewBuilder private var ssoRows: some View {
        SettingsCardBlock(verticalPadding: Studio.Space.s) {
            Text(L10n.t("Single sign-on (advanced)"))
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityAddTraits(.isHeader)
        }
        SettingRow(L10n.t("Trust a proxy’s identity header"),
                   detail: L10n.t("For an SSO reverse proxy that authenticates users itself. Only enable "
                       + "it behind such a proxy — otherwise anyone can set the header.")) {
            SettingSwitch(isOn: setting(vm, \.remoteTrustedHeaderAuthEnabled))
                .managed(.remoteTrustedHeaderAuthEnabled, vm.managedPolicy)
        }
        if vm.settings.remoteTrustedHeaderAuthEnabled {
            SettingRow(L10n.t("Header name"), detail: L10n.t("e.g. X-Forwarded-User."), isIndented: true) {
                SettingsTextField(text: setting(vm, \.remoteTrustedHeaderName), width: 170,
                                  placeholder: L10n.t("X-Forwarded-User"), isMonospaced: true)
                    .managed(.remoteTrustedHeaderName, vm.managedPolicy)
            }
            SettingRow(L10n.t("Trusted proxies"),
                       detail: L10n.t("Comma-separated IPs/CIDRs. Checked against the kernel-supplied peer address. "
                           + "Empty means trust nobody — the header is ignored until you list one."),
                       isIndented: true) {
                SettingsTextField(text: trustedProxiesBinding, width: 180,
                                  placeholder: L10n.t("10.0.0.1, 10.0.0.0/8"), isMonospaced: true)
                    .managed(.remoteTrustedProxies, vm.managedPolicy)
            }
        }
    }

    private var backoffSecondsBinding: Binding<Int> {
        Binding(
            get: { Int(vm.settings.remoteLoginBackoffSeconds.rounded()) },
            set: { seconds in
                vm.update { $0.remoteLoginBackoffSeconds = Double(max(0, seconds)) }
            }
        )
    }

    private var allowedHostNamesBinding: Binding<String> {
        Binding(
            get: { hostNamesDraft ?? vm.settings.remoteAllowedHostNames.joined(separator: ", ") },
            set: { hostNamesDraft = $0 }
        )
    }

    /// `validated()` strips schemes, ports and junk, so a pasted URL still lands as a bare name.
    private func commitHostNames() {
        guard let raw = hostNamesDraft else { return }
        hostNamesDraft = nil
        let parsed = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        vm.update { $0.remoteAllowedHostNames = parsed }
    }

    /// Blank entries must be dropped: a trailing comma would look configured but match nothing.
    private var trustedProxiesBinding: Binding<String> {
        Binding(
            get: { vm.settings.remoteTrustedProxies.joined(separator: ", ") },
            set: { raw in
                let parsed = raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                vm.update { $0.remoteTrustedProxies = parsed }
            }
        )
    }
}
