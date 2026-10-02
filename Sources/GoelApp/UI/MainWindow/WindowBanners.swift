import SwiftUI
import GoelCore

/// Warnings across the top of the main column: the database couldn't be opened (not dismissible
/// while nothing is being saved, so it can't be forgotten) and the saved-servers file is unreadable.
/// The copied-link suggestion is not here: it lives inside the omnibox.
struct WindowBanners: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let persistence = vm.persistenceWarning
        let servers = vm.serverStoreWarning
        if persistence != nil || servers != nil {
            VStack(spacing: Studio.Space.s) {
                if let warning = persistence {
                    WarningBanner(
                        message: warning,
                        actionTitle: vm.databaseRecovery != nil ? L10n.t("Move the Broken Database Aside…") : nil,
                        action: confirmDatabaseRecovery,
                        dismiss: vm.isStoreEphemeral ? nil : { vm.persistenceWarning = nil })
                }
                if let warning = servers {
                    WarningBanner(message: warning, dismiss: { vm.serverStoreWarning = nil })
                }
            }
            .padding(.horizontal, Studio.Space.gutter)
            .padding(.top, Studio.Space.m)
        }
    }

    private func confirmDatabaseRecovery() {
        guard let recovery = vm.databaseRecovery else { return }
        vm.requestConfirm(
            title: L10n.t("Move the broken database aside and start fresh?"),
            message: L10n.t("Goel° couldn’t open %1$@ (%2$@). It will be renamed, not deleted, so nothing is lost; "
                + "the next launch starts with an empty list.",
                            (recovery.path as NSString).lastPathComponent, recovery.reason),
            confirmTitle: L10n.t("Move Aside")
        ) { vm.moveBrokenDatabaseAside() }
    }
}

/// A warn-toned strip (`.note.warn`) with an optional fix and an optional dismiss.
struct WarningBanner: View {
    let message: String
    var actionTitle: String?
    var action: () -> Void = {}
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Studio.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .studioFont(.ui, size: 13, weight: 650)
                .foregroundStyle(Studio.Palette.warn)
                .accessibilityHidden(true)
            Text(message)
                .studioFont(.callout.weight(500))
                .foregroundStyle(Studio.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(L10n.t("Warning. %@", message))
            Spacer(minLength: Studio.Space.s)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.studio(.secondary, size: .small))
            }
            if let dismiss {
                StudioIconButton("xmark", label: L10n.t("Dismiss warning"), size: .small, action: dismiss)
            }
        }
        .padding(.leading, Studio.Space.m)
        .padding(.trailing, Studio.Space.xs)
        .padding(.vertical, Studio.Space.xs)
        .frame(minHeight: 40)
        .background(Studio.Palette.warnSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
    }
}
