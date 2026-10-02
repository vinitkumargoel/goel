import SwiftUI
import AppKit
import GoelCore

/// Web Access: the browser portal — switch, port, the QR code for a phone, who may sign in, the
/// API token, and hardening in its own card.
struct WebAccessSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Never bind the plaintext to settings — only the hash computed on "Set" is persisted.
    @State private var newPassword = ""
    @State private var showsHardening: Bool

    init(showsHardening: Bool = false) {
        _showsHardening = State(initialValue: showsHardening)
    }

    private static let managedKeys: [ManagedPolicy.Key] = [
        .remoteAccessEnabled, .remoteAllowLAN, .remoteRequireAuth, .remoteReadOnly,
        .remoteTLSEnabled, .remoteTLSIdentityPath,
        .remoteTrustedHeaderAuthEnabled, .remoteTrustedHeaderName, .remoteTrustedProxies,
        .remoteAllowedHostNames,
    ]

    var body: some View {
        SettingsPane(title: L10n.t("Web Access"),
                     subtitle: L10n.t("Run the full download manager in a browser — add, stream, and manage "
                                      + "everything from your phone or another Mac."),
                     managedKeys: Self.managedKeys, fillsWidth: true) {
            VStack(alignment: .leading, spacing: Studio.Space.l) {
                SettingsColumns(spacing: Studio.Space.l) {
                    portalCard
                    if vm.settings.remoteAccessEnabled {
                        openCard
                        lookCard
                        accessCard
                            .settingsColumn(.trailing)
                    }
                }
                // Full width: its long explanations need the room.
                if vm.settings.remoteAccessEnabled {
                    WebAccessHardeningCard(isExpanded: $showsHardening)
                }
            }
        }
    }

    private var portalCard: some View {
        SettingsCard(title: L10n.t("Portal"), symbol: "iphone") {
            SettingRow(L10n.t("Enable web portal"),
                       detail: L10n.t("Serves the browser UI and JSON API on the port below.")) {
                SettingSwitch(isOn: enabledBinding)
                    .managed(.remoteAccessEnabled, vm.managedPolicy)
            }
            if vm.settings.remoteAccessEnabled {
                SettingRow(L10n.t("Port"), detail: L10n.t("TCP port the embedded server listens on.")) {
                    SettingsIntField(value: setting(vm, \.remotePort), width: 90)
                }
                if let failure = vm.remotePortalFailure {
                    SettingRow(L10n.t("Web access is not running"), detail: failure) { EmptyView() }
                        .background(Studio.Palette.badSoft)
                }
            }
        }
    }

    /// "Scan from your phone" with the QR code when the LAN is allowed, plus Open portal / Copy Link.
    private var openCard: some View {
        StudioCard {
            HStack(alignment: .center, spacing: Studio.Space.l) {
                if vm.settings.remoteAllowLAN, let lanURL {
                    QRCodeView(text: lanURL.absoluteString)
                        .padding(Studio.Space.xs)
                        .background(Studio.Palette.card,
                                    in: RoundedRectangle(cornerRadius: Studio.Radius.tile, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.tile, style: .continuous)
                            .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: Studio.Space.xs) {
                    Text(vm.settings.remoteAllowLAN ? L10n.t("Scan from your phone") : L10n.t("Open portal"))
                        .studioFont(.title3)
                        .foregroundStyle(Studio.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                        .settingsHighlightBlock(L10n.t("Scan from your phone"))
                    if vm.settings.remoteAllowLAN, let lanHost {
                        Text(verbatim: lanHost)
                            .studioFont(.mono)
                            .foregroundStyle(Studio.Palette.ink)
                            .textSelection(.enabled)
                    }
                    Text(openDetail)
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Studio.Space.s) { portalButtons }
                        VStack(alignment: .leading, spacing: Studio.Space.xs) { portalButtons }
                    }
                    .padding(.top, Studio.Space.xxs)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var portalButtons: some View {
        Button(L10n.t("Open portal"), systemImage: "arrow.up.right.square") {
            if let url = controlURL { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(.studio(.secondary, size: .small))
        .fixedSize()
        .disabled(controlURL == nil || vm.remotePortalFailure != nil)
        .accessibilityLabel(L10n.t("Open web portal in browser"))
        Button(L10n.t("Copy Link"), systemImage: "doc.on.doc") {
            if let url = controlURL { vm.copyToPasteboard(url.absoluteString) }
        }
        .buttonStyle(.studio(.secondary, size: .small))
        .fixedSize()
        .disabled(controlURL == nil || vm.remotePortalFailure != nil)
        .accessibilityLabel(L10n.t("Copy web portal link"))
    }

    private var openDetail: String {
        guard vm.settings.remoteAllowLAN else { return L10n.t("Open it here, or from another device on your LAN.") }
        return lanURL == nil
            ? L10n.t("Advertised via Bonjour. No LAN address detected right now.")
            : L10n.t("Point the camera at the code to open the portal. Also advertised via Bonjour.")
    }

    private var accessCard: some View {
        SettingsCard(title: L10n.t("Access"), symbol: "person.badge.key") {
            SettingRow(L10n.t("Require sign-in"),
                       detail: L10n.t("Prompt for a username and password (recommended). Off = open access — only "
                                      + "safe on localhost.")) {
                SettingSwitch(isOn: setting(vm, \.remoteRequireAuth))
                    .managed(.remoteRequireAuth, vm.managedPolicy)
            }
            if vm.settings.remoteRequireAuth {
                SettingRow(L10n.t("Username"), isIndented: true) {
                    SettingsTextField(text: setting(vm, \.remoteUsername), width: 150)
                }
                SettingRow(L10n.t("Password"),
                           detail: vm.hasRemotePassword
                               ? L10n.t("A password is set. Type a new one to change it.")
                               : L10n.t("No password set yet — sign-in will fail until you set one."),
                           isIndented: true) {
                    HStack(spacing: Studio.Space.xs) {
                        SettingsSecureField(text: $newPassword, width: 130,
                                            accessibilityName: L10n.t("New portal password"))
                        Button(L10n.t("Set")) {
                            vm.setRemotePassword(newPassword)
                            newPassword = ""
                        }
                        .buttonStyle(.studio(.secondary, size: .small))
                        .disabled(newPassword.isEmpty)
                        .accessibilityLabel(L10n.t("Set portal password"))
                    }
                }
            }
            SettingRow(L10n.t("Allow access from the network"),
                       detail: L10n.t("Off = this Mac only (localhost). On = any device on your LAN.")) {
                SettingSwitch(isOn: setting(vm, \.remoteAllowLAN))
                    .managed(.remoteAllowLAN, vm.managedPolicy)
            }
            SettingRow(L10n.t("Read-only mode"),
                       detail: L10n.t("Let clients view and stream, but not add, remove, or change downloads.")) {
                SettingSwitch(isOn: setting(vm, \.remoteReadOnly))
                    .managed(.remoteReadOnly, vm.managedPolicy)
            }
            SettingRow(L10n.t("Session timeout"),
                       detail: L10n.t("Minutes a browser stays signed in before re-login.")) {
                SettingsIntField(value: setting(vm, \.remoteSessionMinutes), unit: L10n.t("min"), width: 100)
            }
        }
    }

    private var lookCard: some View {
        SettingsCard(title: L10n.t("Theme & API"), symbol: "paintpalette") {
            SettingRow(L10n.t("Web theme"),
                       detail: L10n.t("What the portal shows until someone picks a theme in their browser. Separate "
                                      + "from this app’s appearance.")) {
                SettingsSelect(selection: $vm.remoteTheme,
                               options: RemotePortalTheme.allCases.map { SettingsOption($0, $0.title) },
                               width: 140, accessibilityName: L10n.t("Web portal theme"))
            }
            SettingRow(L10n.t("API token"),
                       detail: L10n.t("For scripts and the browser extension. People should use the sign-in above.")) {
                Button(L10n.t("Regenerate")) { confirmRegenerate() }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .accessibilityLabel(L10n.t("Regenerate API token"))
            }
            SettingsCardBlock(showsDivider: false, verticalPadding: 0) {
                Text(verbatim: vm.settings.remoteToken)
                    .studioFont(.monoSmall)
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, Studio.Space.sm)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(Studio.Palette.well,
                                in: RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous))
                    .accessibilityLabel(L10n.t("API token"))
                    .accessibilityValue(vm.settings.remoteToken.map { "\($0) " }.joined())
            }
            .padding(.bottom, Studio.Space.m)
        }
    }

    private func confirmRegenerate() {
        vm.settingsConfirm(
            title: L10n.t("Regenerate the API token?"),
            message: L10n.t("Existing portal links and the paired browser extension stop working until you copy the "
                            + "new token to them."),
            confirmTitle: L10n.t("Regenerate"),
            destructive: true
        ) {
            vm.update { $0.remoteToken = Self.newToken() }
            vm.toastSuccess(L10n.t("New API token generated"))
        }
    }

    /// Must track the server, which fails closed onto TLS; an `http://` link would just not connect.
    private var scheme: String {
        vm.settings.remoteTLSEnabled ? "https" : "http"
    }

    private var lanURL: URL? {
        guard let ip = LANAddress.primaryIPv4() else { return nil }
        return URL(string: "\(scheme)://\(ip):\(vm.settings.remotePort)/?token=\(vm.settings.remoteToken)")
    }

    /// The address without the token, for reading aloud or typing.
    private var lanHost: String? {
        guard let ip = LANAddress.primaryIPv4() else { return nil }
        return "\(scheme)://\(ip):\(vm.settings.remotePort)"
    }

    /// Mints the token on first enable, so the server never starts unauthenticated.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { vm.settings.remoteAccessEnabled },
            set: { enabled in
                vm.update {
                    $0.remoteAccessEnabled = enabled
                    if enabled, $0.remoteToken.isEmpty { $0.remoteToken = Self.newToken() }
                }
            }
        )
    }

    private var controlURL: URL? {
        URL(string: "\(scheme)://127.0.0.1:\(vm.settings.remotePort)/?token=\(vm.settings.remoteToken)")
    }

    // `nonisolated`: without it this inherits `View`'s main-actor isolation and won't compile inside `update`.
    private nonisolated static func newToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
