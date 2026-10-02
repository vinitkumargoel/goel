import SwiftUI
import AppKit
import SafariServices
import GoelCore

/// One live card per installed browser, each showing its real helper / extension state, with the
/// numbered steps still missing and a single primary fix.
struct BrowserStatusCards: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var statuses: [BrowserStatus]
    @State private var safariEnabled: Bool?
    private let isLive: Bool

    static let safariExtensionID = "com.goel.downloader.SafariExtension"

    init() {
        _statuses = State(initialValue: [])
        _safariEnabled = State(initialValue: nil)
        isLive = true
    }

    /// Fixed states, for snapshots: no polling.
    init(previewStatuses: [BrowserStatus], safariEnabled: Bool?) {
        _statuses = State(initialValue: previewStatuses)
        _safariEnabled = State(initialValue: safariEnabled)
        isLive = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            SafariCard(enabled: safariEnabled, onOpen: openSafariPrefs)
            ForEach(statuses) { status in
                BrowserCard(status: status, onFix: { fix(status) })
            }
            if statuses.isEmpty {
                StudioNote(tone: .neutral, symbol: "info.circle",
                           message: L10n.t("No Chromium browser or Firefox profile found. Open your browser once, then come back."))
            }
        }
        .task {
            guard isLive else { return }
            await refreshLoop()
        }
    }

    /// Re-reads every few seconds while the pane is open, so installing the extension shows up live.
    private func refreshLoop() async {
        while !Task.isCancelled {
            statuses = BrowserIntegrationService.statuses()
            safariEnabled = await Self.safariState()
            try? await Task.sleep(for: .seconds(4))
        }
    }

    static func safariState() async -> Bool? {
        await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: safariExtensionID) { state, error in
                continuation.resume(returning: error == nil ? state?.isEnabled : nil)
            }
        }
    }

    private func fix(_ status: BrowserStatus) {
        switch BrowserCard.primaryFix(for: status) {
        case .installHelper:
            vm.toastNow(BrowserIntegrationService.installHostManifests())
            statuses = BrowserIntegrationService.statuses()
        case .showExtension:
            if let folder = BrowserIntegrationService.extensionFolder {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } else {
                vm.toastWarning(L10n.t("The bundled extension folder is only in the packaged app"))
            }
        case .none:
            break
        }
    }

    private func openSafariPrefs() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.safariExtensionID) { error in
            guard error != nil else { return }
            Task { @MainActor in
                vm.toastWarning(L10n.t("Open Safari ▸ Settings ▸ Extensions manually"))
            }
        }
    }
}

/// A Chromium or Firefox browser: helper and extension state, the steps left, and the one fix.
struct BrowserCard: View {
    enum Fix: Equatable { case installHelper, showExtension, none }

    let status: BrowserStatus
    let onFix: () -> Void

    static func primaryFix(for status: BrowserStatus) -> Fix {
        if status.helper != .installed { return .installHelper }
        if status.lastSeen == nil { return .showExtension }
        return .none
    }

    private var fix: Fix { Self.primaryFix(for: status) }
    private var helperDone: Bool { status.helper == .installed }
    private var extensionDone: Bool { status.lastSeen != nil }

    var body: some View {
        StudioCard(padding: Studio.Space.ml) {
            VStack(alignment: .leading, spacing: Studio.Space.sm) {
                HStack(spacing: Studio.Space.m) {
                    BrowserTile(kind: status.name.localizedCaseInsensitiveContains("firefox") ? .video : .magnet,
                                symbol: "globe")
                    VStack(alignment: .leading, spacing: Studio.Space.hair) {
                        Text(status.name)
                            .studioFont(.bodyStrong)
                            .foregroundStyle(Studio.Palette.ink)
                        Text(helperText + " · " + extensionText)
                            .studioFont(.tiny)
                            .foregroundStyle(Studio.Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Studio.Space.s)
                    if fix == .none {
                        StudioPill(L10n.t("Ready"), tone: .good)
                    } else {
                        StudioPill(stepsLeftText, tone: .warn)
                    }
                }
                if fix != .none {
                    VStack(alignment: .leading, spacing: Studio.Space.xs) {
                        BrowserStep(number: 1, title: L10n.t("Install the messaging helper"), isDone: helperDone) {
                            if fix == .installHelper {
                                Button(status.helper == .stale ? L10n.t("Repair Helper") : L10n.t("Install Helper"),
                                       action: onFix)
                                    .buttonStyle(.studio(.primary, size: .small))
                            }
                        }
                        BrowserStep(number: 2, title: L10n.t("Load the extension"), isDone: extensionDone) {
                            if fix == .showExtension {
                                Button(L10n.t("Show Extension"), action: onFix)
                                    .buttonStyle(.studio(.primary, size: .small))
                            }
                        }
                        BrowserStep(number: 3, title: L10n.t("Restart the browser"), isDone: extensionDone) {
                            EmptyView()
                        }
                    }
                    .padding(.leading, Studio.Space.xxs)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.name)
    }

    private var stepsLeftText: String {
        let left = [helperDone, extensionDone].filter { !$0 }.count
        return left == 1 ? L10n.t("1 step left") : L10n.t("%d steps left", left)
    }

    private var helperText: String {
        switch status.helper {
        case .installed: return L10n.t("Helper installed")
        case .missing: return L10n.t("Helper not installed")
        case .stale: return L10n.t("Helper points at a moved copy of the app")
        }
    }

    private var extensionText: String {
        guard let seen = status.lastSeen else { return L10n.t("Extension not seen yet") }
        let seenText = seen.formatted(.relative(presentation: .named))
        guard let capture = status.lastCapture else { return L10n.t("Extension seen %@", seenText) }
        return L10n.t("Last capture %@", capture.formatted(.relative(presentation: .named)))
    }
}

/// One numbered step: a check once done, otherwise its number, and an optional action.
private struct BrowserStep<Action: View>: View {
    let number: Int
    let title: String
    let isDone: Bool
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            if isDone {
                Image(systemName: "checkmark")
                    .studioFont(.ui, size: 11.5, weight: 700)
                    .foregroundStyle(Studio.Palette.good)
                    .frame(width: 18, alignment: .leading)
            } else {
                Text(verbatim: "\(number).")
                    .studioFont(.monoSmall)
                    .foregroundStyle(Studio.Palette.ink3)
                    .frame(width: 18, alignment: .leading)
            }
            Text(title)
                .studioFont(.small)
                .foregroundStyle(isDone ? Studio.Palette.good : Studio.Palette.ink)
            action()
                .fixedSize()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 27)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? L10n.t("Done") : "")
    }
}

/// Safari: the extension ships inside the app, so the only state is on, off, or not registered.
private struct SafariCard: View {
    let enabled: Bool?
    let onOpen: () -> Void

    var body: some View {
        StudioCard(padding: Studio.Space.ml) {
            HStack(spacing: Studio.Space.m) {
                BrowserTile(kind: .app, symbol: "safari")
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    Text(verbatim: "Safari")
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                    Text(stateText)
                        .studioFont(.tiny)
                        .foregroundStyle(enabled == true ? Studio.Palette.ink3 : Studio.Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Studio.Space.s)
                if enabled == true {
                    StudioPill(L10n.t("Ready"), tone: .good)
                } else {
                    Button(L10n.t("Open Safari Extensions"), action: onOpen)
                        .buttonStyle(.studio(.primary, size: .small))
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Safari")
    }

    private var stateText: String {
        switch enabled {
        case .some(true): return L10n.t("Extension enabled")
        case .some(false): return L10n.t("Extension turned off in Safari")
        case .none: return L10n.t("Extension not registered — open the installed app once, then Safari")
        }
    }
}

/// The small coloured artwork tile (`.art.s`) a browser card leads with.
private struct BrowserTile: View {
    let kind: StudioArtKind
    let symbol: String

    var body: some View {
        let tint = Studio.Palette.fileTint(kind)
        Image(systemName: symbol)
            .studioFont(.ui, size: 15, weight: 650)
            .foregroundStyle(tint.glyph)
            .frame(width: 32, height: 32)
            .background(LinearGradient(colors: [tint.fill, tint.fillDeep], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: Studio.Radius.artSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Studio.Radius.artSmall, style: .continuous)
                .strokeBorder(Studio.Palette.artHighlight, lineWidth: 1))
            .accessibilityHidden(true)
    }
}
