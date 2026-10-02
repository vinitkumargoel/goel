import SwiftUI
import GoelCore

/// Notifications: which events show a banner, and whether macOS lets them through.
struct NotificationsSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var permission: NotificationService.Permission?
    private let checksPermission: Bool

    /// Snapshots pass a fixed permission and skip asking the system.
    init(permission: NotificationService.Permission? = nil) {
        _permission = State(initialValue: permission)
        checksPermission = permission == nil
    }

    var body: some View {
        SettingsPane(title: L10n.t("Notifications"),
                     subtitle: L10n.t("Which events show a banner, and whether macOS lets them through.")) {
            SettingsCard(title: L10n.t("Permission"), symbol: "bell.badge") {
                permissionRow
            }
            SettingsCard(title: L10n.t("Notify me"), symbol: "bell") {
                SettingRow(L10n.t("On download added"),
                           detail: L10n.t("A banner each time something joins the queue."),
                           isOn: setting(vm, \.notifyOnAdded))
                SettingRow(L10n.t("On download completed"),
                           detail: L10n.t("A banner the moment a file is ready."),
                           isOn: setting(vm, \.notifyOnCompleted))
                SettingRow(L10n.t("On download failed"),
                           detail: L10n.t("Says why, so you can retry without opening the app."),
                           isOn: setting(vm, \.notifyOnFailed))
                SettingRow(L10n.t("Only when app is inactive"),
                           detail: L10n.t("Stay quiet while Goel° is the frontmost app."),
                           isOn: setting(vm, \.notifyOnlyWhenInactive))
                SettingRow(L10n.t("Play sound"), detail: L10n.t("The system alert sound with each banner."),
                           isOn: setting(vm, \.notificationSound))
            }
            .settingsColumn(.trailing)
        }
        .task {
            guard checksPermission else { return }
            permission = await NotificationService.permission()
        }
    }

    private var permissionRow: some View {
        SettingsCardBlock(showsDivider: false) {
            HStack(spacing: Studio.Space.s) {
                StudioPill(permissionTitle, tone: permissionTone)
                Spacer(minLength: 0)
            }
            Text(permissionText)
                .studioFont(.caption)
                .foregroundStyle(Studio.Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .settingsHighlightBlock(L10n.t("Permission"))
            HStack(spacing: Studio.Space.s) {
                if permission == .denied {
                    Button(L10n.t("Open System Settings…")) { NotificationService.openSystemSettings() }
                        .buttonStyle(.studio(.primary, size: .small))
                } else if permission == .notAsked {
                    Button(L10n.t("Allow…")) {
                        NotificationService.requestAuthorization()
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            permission = await NotificationService.permission()
                        }
                    }
                    .buttonStyle(.studio(.primary, size: .small))
                }
                Button(L10n.t("Send Test"), systemImage: "paperplane") {
                    NotificationService.sendTest(sound: vm.settings.notificationSound)
                }
                .buttonStyle(.studio(.secondary, size: .small))
                .disabled(permission == .denied)
            }
            .padding(.top, Studio.Space.xxs)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Permission"))
    }

    private var permissionTitle: String {
        switch permission {
        case .allowed: return L10n.t("Allowed")
        case .denied: return L10n.t("Turned off")
        case .notAsked: return L10n.t("Not asked yet")
        case nil: return L10n.t("Checking…")
        }
    }

    private var permissionTone: StudioTone {
        switch permission {
        case .allowed: return .good
        case .denied: return .bad
        case .notAsked: return .warn
        case nil: return .neutral
        }
    }

    private var permissionText: String {
        switch permission {
        case .allowed: return L10n.t("Allowed — banners appear.")
        case .denied: return L10n.t("Turned off in System Settings — no banners will appear.")
        case .notAsked: return L10n.t("Not asked yet — macOS asks the first time a banner is due.")
        case nil: return L10n.t("Checking…")
        }
    }
}

/// Network: proxy, timeouts, retries, and authentication.
struct NetworkSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Network"), subtitle: L10n.t("Proxy, timeouts, retries, and authentication."),
                     managedKeys: [.proxyMode, .proxyType, .proxyHost, .proxyPort]) {
            proxyCard
            awarenessCard
            connectionsCard
                .settingsColumn(.trailing)
        }
    }

    private var proxyCard: some View {
        SettingsCard(title: L10n.t("Proxy"), symbol: "network") {
            SettingRow(L10n.t("Proxy"),
                       detail: L10n.t("Route traffic through a proxy server. Multi-path aggregation is disabled "
                           + "while a system or manual proxy is set.")) {
                SettingsSelect(selection: setting(vm, \.proxyMode), options: [
                    SettingsOption("none", L10n.t("None")),
                    SettingsOption("system", L10n.t("System")),
                    SettingsOption("manual", L10n.t("Manual")),
                ], width: 130)
                .managed(.proxyMode, vm.managedPolicy)
            }
            if vm.settings.proxyMode == "manual" {
                SettingRow(L10n.t("Proxy type"), detail: L10n.t("HTTP or SOCKS5 (applies to HTTP/HTTPS downloads)."),
                           isIndented: true) {
                    SettingsSelect(selection: setting(vm, \.proxyType), options: [
                        SettingsOption("http", "HTTP"),
                        SettingsOption("socks5", "SOCKS5"),
                    ], width: 130)
                    .managed(.proxyType, vm.managedPolicy)
                }
                SettingRow(L10n.t("Proxy host"), detail: L10n.t("Hostname or IP of the proxy server."),
                           isIndented: true) {
                    SettingsTextField(text: setting(vm, \.proxyHost), width: 160,
                                      placeholder: L10n.t("proxy.example.com"), isMonospaced: true)
                        .managed(.proxyHost, vm.managedPolicy)
                }
                SettingRow(L10n.t("Proxy port"), detail: L10n.t("Port the proxy listens on."), isIndented: true) {
                    SettingsIntField(value: setting(vm, \.proxyPort))
                        .managed(.proxyPort, vm.managedPolicy)
                }
            }
        }
    }

    private var connectionsCard: some View {
        SettingsCard(title: L10n.t("Connections"), symbol: "arrow.triangle.2.circlepath") {
            SettingRow(L10n.t("Connection timeout"), detail: L10n.t("Seconds before a stalled connection drops.")) {
                SettingsDoubleField(value: setting(vm, \.connectionTimeout), unit: L10n.t("s"))
            }
            SettingRow(L10n.t("Retry count"), detail: L10n.t("Attempts before marking a download failed.")) {
                SettingsIntField(value: setting(vm, \.retryCount))
            }
            SettingRow(L10n.t("Retry interval"), detail: L10n.t("Seconds to wait between retries.")) {
                SettingsDoubleField(value: setting(vm, \.retryInterval), unit: L10n.t("s"))
            }
            SettingRow(L10n.t("Auto-retry failed downloads"),
                       detail: L10n.t("Automatically re-queue a failed download and try again, with an exponential "
                           + "backoff between attempts."),
                       isOn: setting(vm, \.autoRetryEnabled))
            if vm.settings.autoRetryEnabled {
                SettingRow(L10n.t("Auto-retry attempts"),
                           detail: L10n.t("How many times to retry before leaving it failed for a manual retry."),
                           isIndented: true) {
                    SettingsIntField(value: setting(vm, \.autoRetryMaxAttempts))
                }
            }
            SettingRow(L10n.t("Custom user-agent"), detail: L10n.t("Sent with HTTP requests.")) {
                SettingsTextField(text: setting(vm, \.userAgent), width: 160, placeholder: L10n.t("Default"))
            }
            SettingRow(L10n.t("Cookie / auth handling"), detail: L10n.t("Reuse cookies for protected downloads."),
                       isOn: setting(vm, \.cookieAuthEnabled))
            SettingRow(L10n.t("Re-download when remote changes"),
                       detail: L10n.t("Periodically re-check finished HTTP downloads and fetch again if the "
                           + "server’s file changed."),
                       isOn: setting(vm, \.autoRedownloadOnRemoteChange))
        }
    }

    private var awarenessCard: some View {
        SettingsCard(title: L10n.t("Network awareness"), symbol: "wifi") {
            SettingRow(L10n.t("Pause on expensive networks"),
                       detail: L10n.t("Hold downloads while on a personal hotspot; resume automatically after."),
                       isOn: setting(vm, \.pauseOnExpensiveNetwork))
            SettingRow(L10n.t("Pause in Low Data Mode"),
                       detail: L10n.t("Hold downloads while the connection is constrained."),
                       isOn: setting(vm, \.pauseOnConstrainedNetwork))
        }
    }
}
