import SwiftUI
import AppKit
import GoelCore

/// The Settings window: a searchable pane list grouped as Basics / Transfers / After download /
/// Integrations / Admin on the left, the selected pane's cards on the right.
struct SettingsView: View {
    @EnvironmentObject private var vm: AppViewModel

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case rules = "Rules"
        case notifications = "Notifications"
        case network = "Network"
        case traffic = "Speed & Connections"
        case bittorrent = "BitTorrent"
        case scheduler = "Scheduler"
        case rss = "RSS Feeds"
        case aggregation = "Multi-path"
        case afterDownload = "Extract & Scripts"
        case antivirus = "Antivirus"
        case media = "Media Tools"
        case browser = "Browser"
        case remote = "Web Access"
        case backup = "Backup & Updates"
        case audit = "Audit Log"
        case diagnostics = "Diagnostics"
        case license = "Licence"
        var id: String { rawValue }

        /// The localized pane name.
        var title: String { L10n.t(rawValue) }

        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .rules: return "line.3.horizontal.decrease.circle"
            case .notifications: return "bell"
            case .network: return "globe"
            case .traffic: return "gauge.with.dots.needle.33percent"
            case .bittorrent: return "circle.grid.cross"
            case .scheduler: return "calendar"
            case .rss: return "dot.radiowaves.up.forward"
            case .aggregation: return "point.3.connected.trianglepath.dotted"
            case .afterDownload: return "archivebox"
            case .antivirus: return "shield"
            case .media: return "film"
            case .browser: return "powerplug"
            case .remote: return "iphone"
            case .backup: return "arrow.triangle.2.circlepath"
            case .audit: return "doc.text.magnifyingglass"
            case .diagnostics: return "stethoscope"
            case .license: return "checkmark.seal"
            }
        }
    }

    @State private var selection: Pane
    @State private var searchText: String
    /// What VoiceOver last heard about the results, so an unchanged result set isn't re-announced per keystroke.
    @State private var announcedResults: [Pane]?

    @ObservedObject private var route = SettingsRoute.shared

    init() {
        self.init(initialPane: .general)
    }

    /// Opens on `initialPane`, optionally with a search already typed (snapshots, previews).
    init(initialPane: Pane, initialSearch: String = "") {
        _selection = State(initialValue: initialPane)
        _searchText = State(initialValue: initialSearch)
    }

    private var matchingPanes: [Pane] { SettingsSearch.panes(matching: searchText) }

    var body: some View {
        let matches = matchingPanes
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection, searchText: $searchText, matches: matches)
                .frame(width: 230)
            Rectangle()
                .fill(Studio.Palette.hairline)
                .frame(width: 1)
                .accessibilityHidden(true)
            Group {
                if matches.isEmpty {
                    // The pane from before the search must not stay on screen as if it matched.
                    noMatchContent
                } else {
                    ScrollView {
                        SettingsPaneContent(pane: selection)
                            .padding(.horizontal, Studio.Space.xxl)
                            .padding(.top, Studio.Space.xl)
                            .padding(.bottom, Studio.Space.xxl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollContentBackground(.hidden)
                    .environment(\.settingsSearchQuery, searchText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Studio.Palette.canvas)
        }
        .studioWindowBackground()
        // Follow the filter: a pane the search hides must not stay on screen as if it matched.
        .onChange(of: searchText) { _, query in
            let panes = matchingPanes
            if let first = panes.first, !panes.contains(selection) { selection = first }
            announceResults(panes, for: query)
        }
        // Clear the request once consumed, or asking for the same pane twice never fires onChange again.
        .onChange(of: route.requestedPane) { _, requested in
            guard let requested else { return }
            consume(requested)
        }
        .onAppear {
            if let requested = route.requestedPane { consume(requested) }
        }
        .overlay(alignment: .bottom) { ToastOverlay(queue: vm.toasts, bottomPadding: 24) }
        .alert(vm.settingsAlert?.title ?? "",
               isPresented: Binding(get: { vm.settingsAlert != nil },
                                    set: { if !$0 { vm.settingsAlert = nil } }),
               presenting: vm.settingsAlert) { alert in
            if let confirmTitle = alert.confirmTitle {
                Button(confirmTitle, role: alert.isDestructive ? .destructive : nil) {
                    alert.onConfirm?()
                }
                Button(L10n.t("Cancel"), role: .cancel) { }
            } else {
                Button(L10n.t("OK"), role: .cancel) { }
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    private func consume(_ requested: Pane) {
        searchText = route.requestedHighlight ?? ""
        route.requestedHighlight = nil
        selection = requested
        route.requestedPane = nil
    }

    private var noMatchContent: some View {
        StudioEmptyState(symbol: "magnifyingglass",
                         title: L10n.t("No settings match"),
                         message: L10n.t("Try a different word, or clear the search to see every pane.")) {
            Button(L10n.t("Clear Search")) { searchText = "" }
                .buttonStyle(.studio(.secondary, size: .small))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func announceResults(_ panes: [Pane], for query: String) {
        guard SettingsSearch.isActive(query) else {
            announcedResults = nil
            return
        }
        guard panes != announcedResults else { return }
        announcedResults = panes
        A11yAnnouncer.announce(SettingsSearch.resultAnnouncement(count: panes.count))
    }
}

/// The selected pane's content.
struct SettingsPaneContent: View {
    let pane: SettingsView.Pane

    #if DEBUG
    @Environment(\.settingsPreviewFixtures) private var fixtures
    #endif

    var body: some View {
        #if DEBUG
        if let fixtures {
            fixtureContent(fixtures)
        } else {
            liveContent
        }
        #else
        liveContent
        #endif
    }

    @ViewBuilder private var liveContent: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .rules: RulesSettingsPane()
        case .notifications: NotificationsSettingsPane()
        case .network: NetworkSettingsPane()
        case .traffic: SpeedSettingsPane()
        case .bittorrent: BitTorrentSettingsPane()
        case .scheduler: SchedulerSettingsPane()
        case .rss: RSSSettingsPane()
        case .aggregation: MultipathSettingsPane()
        case .afterDownload: ExtractScriptsSettingsPane()
        case .antivirus: AntivirusSettingsPane()
        case .media: MediaToolsSettingsPane()
        case .browser: BrowserSettingsPane()
        case .remote: WebAccessSettingsPane()
        case .backup: BackupUpdatesSettingsPane()
        case .audit: AuditLogSettingsPane()
        case .diagnostics: DiagnosticsSettingsPane()
        case .license: LicenceSettingsPane()
        }
    }

    #if DEBUG
    /// The panes that would otherwise read the system (permission, browsers, Keychain, adapters,
    /// the history database) get fixed states instead.
    @ViewBuilder private func fixtureContent(_ fixtures: SettingsPreviewFixtures) -> some View {
        switch pane {
        case .rules: RulesSettingsPane(history: fixtures.ruleHistory)
        case .notifications: NotificationsSettingsPane(permission: fixtures.permission)
        case .aggregation: MultipathSettingsPane(previewAdapters: fixtures.adapters)
        case .browser:
            BrowserSettingsPane(cards: BrowserStatusCards(previewStatuses: fixtures.browserStatuses,
                                                          safariEnabled: fixtures.safariEnabled),
                                credentialStore: fixtures.credentials)
        case .remote: WebAccessSettingsPane(showsHardening: fixtures.showsHardening)
        default: liveContent
        }
    }
    #endif
}

#if DEBUG
/// Fixed states for the snapshot harness, so a snapshot never reads the Keychain, the browsers,
/// the notification permission, the adapters or the history database.
struct SettingsPreviewFixtures {
    var permission: NotificationService.Permission = .allowed
    var browserStatuses: [BrowserStatus] = []
    var safariEnabled: Bool? = true
    var credentials: any CredentialManaging
    var ruleHistory: [AutoSortCandidate] = []
    var adapters: [NetworkAdapter] = []
    var showsHardening = false
}

private struct SettingsPreviewFixturesKey: EnvironmentKey {
    static let defaultValue: SettingsPreviewFixtures? = nil
}

extension EnvironmentValues {
    var settingsPreviewFixtures: SettingsPreviewFixtures? {
        get { self[SettingsPreviewFixturesKey.self] }
        set { self[SettingsPreviewFixturesKey.self] = newValue }
    }
}
#endif
