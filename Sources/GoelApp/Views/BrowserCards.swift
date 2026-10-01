import SwiftUI
import AppKit
import SafariServices
import GoelCore

/// Settings › Browser: one live card per installed browser, each with a single primary fix.
struct BrowserStatusCards: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var statuses: [BrowserStatus] = []
    @State private var safariEnabled: Bool?

    static let safariExtensionID = "com.goel.downloader.SafariExtension"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(statuses) { status in
                BrowserCard(status: status, onFix: { fix(status) })
            }
            SafariCard(enabled: safariEnabled, onOpen: openSafariPrefs)
            if statuses.isEmpty {
                Text(L10n.t("No Chromium browser or Firefox profile found. Open your browser once, then come back."))
                    .scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task { await refreshLoop() }
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

struct BrowserCard: View {
    enum Fix: Equatable { case installHelper, showExtension, none }

    let status: BrowserStatus
    let onFix: () -> Void

    static func primaryFix(for status: BrowserStatus) -> Fix {
        if status.helper != .installed { return .installHelper }
        if status.lastSeen == nil { return .showExtension }
        return .none
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe").scaledFont(size: 18).foregroundStyle(Theme.accent)
                .frame(width: 22).a11yDecorative()
            VStack(alignment: .leading, spacing: 3) {
                Text(status.name).scaledFont(size: Theme.TextSize.body, weight: .semibold)
                statusLine(helperText, ok: status.helper == .installed)
                statusLine(extensionText, ok: status.lastSeen != nil)
            }
            Spacer(minLength: 8)
            fixButton
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.name)
    }

    @ViewBuilder
    private var fixButton: some View {
        switch Self.primaryFix(for: status) {
        case .installHelper:
            Button(status.helper == .stale ? L10n.t("Repair Helper") : L10n.t("Install Helper"), action: onFix)
                .buttonStyle(.borderedProminent)
        case .showExtension:
            Button(L10n.t("Show Extension"), action: onFix)
                .buttonStyle(.bordered)
        case .none:
            Label(L10n.t("Ready"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.green)
                .scaledFont(size: Theme.TextSize.meta, weight: .medium)
        }
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

    private func statusLine(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle" : "exclamationmark.circle")
            .scaledFont(size: Theme.TextSize.meta)
            .foregroundStyle(ok ? Color.secondary : Theme.orange)
    }
}

private struct SafariCard: View {
    let enabled: Bool?
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "safari").scaledFont(size: 18).foregroundStyle(Theme.accent)
                .frame(width: 22).a11yDecorative()
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Safari").scaledFont(size: Theme.TextSize.body, weight: .semibold)
                Label(stateText, systemImage: enabled == true ? "checkmark.circle" : "exclamationmark.circle")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(enabled == true ? Color.secondary : Theme.orange)
            }
            Spacer(minLength: 8)
            if enabled == true {
                Label(L10n.t("Ready"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.green)
                    .scaledFont(size: Theme.TextSize.meta, weight: .medium)
            } else {
                Button(L10n.t("Open Safari Extensions"), action: onOpen)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.primary.opacity(0.04)))
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
