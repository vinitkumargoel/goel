import SwiftUI
import AppKit
import GoelCore

/// What went wrong, why it probably happened, and the next step — instead of a bare red string.
/// When the error points at a specific fix (a login, a new link, a folder with room, the proxy,
/// a busy server) that fix is the filled button; Retry stays beside it as the fallback, and the
/// housekeeping (Copy Details, Show Folder) sits in the "…" menu.
struct FailureCard: View {
    let task: DownloadTask
    let error: DownloadError
    let vm: AppViewModel
    var compact: Bool = false

    @Environment(\.openSettings) private var openSettings
    @State private var sheet: RecoverySheetKind?

    private enum RecoverySheetKind: String, Identifiable {
        case updateLink, cookies, changeFolder
        var id: String { rawValue }
    }

    private var hint: String? { FailureAdvice.hint(for: error) }
    private var recovery: FailureAdvice.Recovery? { FailureAdvice.recovery(for: task, error: error) }

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: 8) {
            VStack(alignment: compact ? .leading : .center, spacing: 4) {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: Theme.TextSize.meta, weight: .medium)
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(compact ? .leading : .center)
                    .lineLimit(compact ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let hint {
                    Text(hint)
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(compact ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(A11y.sentence(error.message, hint))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("Download failed. %@", error.message))
            .accessibilityValue(hint ?? "")

            HStack(spacing: 6) {
                if let recovery {
                    recoveryButton(recovery)
                    cardButton(L10n.t("Retry"), "arrow.clockwise",
                               spoken: L10n.t("Retry %@ now", task.name)) { vm.retry(task.id) }
                } else {
                    cardButton(L10n.t("Retry"), "arrow.clockwise",
                               spoken: L10n.t("Retry %@", task.name), prominent: true) { vm.retry(task.id) }
                }
                moreMenu
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
        .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.red.opacity(0.25)))
        .sheet(item: $sheet) { kind in
            switch kind {
            case .updateLink: UpdateLinkSheet(task: task, vm: vm)
            case .cookies: AttachCookiesSheet(task: task, vm: vm)
            case .changeFolder: ChangeFolderSheet(task: task, vm: vm)
            }
        }
    }

    /// Filled red with the contrast-checked ink: the one action the error itself asks for.
    private func recoveryButton(_ recovery: FailureAdvice.Recovery) -> some View {
        Button { perform(recovery) } label: {
            Label(recovery.title, systemImage: recovery.symbol)
                .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Theme.red, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .foregroundStyle(Theme.onRed)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint ?? recovery.title)
        .a11yButton(A11y.sentence(recovery.title, task.name), hint: hint)
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

    private var moreMenu: some View {
        Menu {
            Button(L10n.t("Copy Details")) {
                vm.copyToPasteboard(FailureAdvice.details(for: task, error: error))
            }
            Button(L10n.t("Show Folder")) { showFolder() }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 24)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.hairline))
        .help(L10n.t("More actions"))
        .accessibilityLabel(L10n.t("More actions for %@", task.name))
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

    private func cardButton(_ title: String, _ symbol: String, spoken: String,
                            prominent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .scaledFont(size: Theme.TextSize.caption, weight: .medium)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(prominent ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.hairline))
                .foregroundStyle(prominent ? Theme.accent : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton(spoken)
    }
}
