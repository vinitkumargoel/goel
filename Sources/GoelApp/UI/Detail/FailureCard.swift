import SwiftUI
import AppKit
import GoelCore

/// What went wrong, why it probably happened, and the next step. When the error points at a
/// specific fix (a login, a new link, a folder with room, the proxy, a busy server) that fix is
/// the filled button and Retry sits beside it; every other fix the download can take is under
/// More actions. `compact` is the bottom dock's shorter form.
struct FailureCard: View {
    let task: DownloadTask
    let error: DownloadError
    var compact = false

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var sheet: RecoverySheetKind?

    enum RecoverySheetKind: String, Identifiable {
        case updateLink, cookies, changeFolder
        var id: String { rawValue }
    }

    private var hint: String? { FailureAdvice.hint(for: error) }
    private var recovery: FailureAdvice.Recovery? { FailureAdvice.recovery(for: task, error: error) }

    /// The fixes this download can take at all; the advised one is already the filled button.
    private var otherRecoveries: [FailureAdvice.Recovery] {
        var all: [FailureAdvice.Recovery] = []
        if task.kind == .http { all += [.attachCookies, .updateLink] }
        if task.kind == .http || task.bytesDownloaded == 0 { all.append(.changeFolder) }
        all.append(.proxySettings)
        return all.filter { $0 != recovery }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Studio.Space.s : Studio.Space.sm) {
            if !compact {
                HStack(spacing: Studio.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(StudioFonts.font(.ui, size: 16, weight: 650))
                        .foregroundStyle(Studio.Palette.bad)
                        .accessibilityHidden(true)
                    Text(L10n.t("Download failed"))
                        .studioFont(.title3)
                        .foregroundStyle(Studio.Palette.ink)
                }
                .accessibilityHidden(true)
            }
            explanation
            DetailFlowLayout(spacing: Studio.Space.xs, lineSpacing: Studio.Space.xs) { actionButtons }
        }
        .padding(compact ? Studio.Space.m : Studio.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.Palette.badSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
        .sheet(item: $sheet) { kind in
            switch kind {
            case .updateLink: UpdateLinkSheet(task: task).environmentObject(vm)
            case .cookies: AttachCookiesSheet(task: task).environmentObject(vm)
            case .changeFolder: ChangeFolderSheet(task: task).environmentObject(vm)
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Studio.Space.xs) {
                if compact {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(StudioFonts.font(.ui, size: 11.5, weight: 650))
                        .foregroundStyle(Studio.Palette.bad)
                }
                Text(error.message)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(compact ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let hint {
                Text(hint)
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !compact, let attempt = task.retryAttempt, vm.settings.autoRetryEnabled {
                Text(L10n.t("Attempt %1$d of %2$d", attempt, vm.settings.autoRetryMaxAttempts))
                    .studioFont(.mono)
                    .foregroundStyle(Studio.Palette.ink3)
            }
        }
        .help(A11y.sentence(error.message, hint))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Download failed. %@", error.message))
        .accessibilityValue(hint ?? "")
    }

    @ViewBuilder private var actionButtons: some View {
        if let recovery {
            Button(recovery.title, systemImage: recovery.symbol) { perform(recovery) }
                .buttonStyle(.studio(.primary, size: .small))
                .help(hint ?? recovery.title)
                .a11yButton(A11y.sentence(recovery.title, task.name), hint: hint)
            Button(L10n.t("Retry"), systemImage: "arrow.clockwise") { vm.retry(task.id) }
                .buttonStyle(.studio(.secondary, size: .small))
                .a11yButton(L10n.t("Retry %@ now", task.name))
        } else {
            Button(L10n.t("Retry"), systemImage: "arrow.clockwise") { vm.retry(task.id) }
                .buttonStyle(.studio(.primary, size: .small))
                .a11yButton(L10n.t("Retry %@", task.name))
        }
        if !compact {
            Button(L10n.t("Copy Details"), systemImage: "doc.on.doc") { copyDetails() }
                .buttonStyle(.studio(.secondary, size: .small))
            Button(L10n.t("Show Folder"), systemImage: "folder") { showFolder() }
                .buttonStyle(.studio(.secondary, size: .small))
        }
        DetailMenuButton(title: compact ? L10n.t("More") : L10n.t("More Actions"),
                         accessibilityLabel: L10n.t("More actions for %@", task.name)) {
            if compact {
                Button(L10n.t("Copy Details")) { copyDetails() }
                Button(L10n.t("Show Folder")) { showFolder() }
                Divider()
            }
            ForEach(otherRecoveries, id: \.title) { option in
                Button(option.title) { perform(option) }
            }
        }
        .help(L10n.t("More actions"))
    }

    private func perform(_ recovery: FailureAdvice.Recovery) {
        switch recovery {
        case .attachCookies: sheet = .cookies
        case .updateLink: sheet = .updateLink
        case .changeFolder: sheet = .changeFolder
        case .proxySettings:
            SettingsRoute.shared.request(.network)
            openSettings()
        case .retryLater(let delay):
            vm.retryLater(task, after: delay)
        }
    }

    private func copyDetails() {
        vm.copyToPasteboard(FailureAdvice.details(for: task, error: error))
    }

    /// A failed download often has no file yet, and revealing a missing file is an error toast;
    /// the folder it was going to land in is what the user wants to look at.
    private func showFolder() {
        let fm = FileManager.default
        if fm.fileExists(atPath: task.savePath) {
            vm.revealInFinder(task)
        } else if fm.fileExists(atPath: task.saveDirectory) {
            NSWorkspace.shared.open(URL(fileURLWithPath: task.saveDirectory, isDirectory: true))
        } else {
            vm.toastNow(L10n.t("The folder “%@” no longer exists",
                               (task.saveDirectory as NSString).abbreviatingWithTildeInPath),
                        isError: true)
        }
    }
}
