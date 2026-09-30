import SwiftUI
import AppKit
import GoelCore

/// What went wrong, why it probably happened, and the next step — instead of a bare red string.
struct FailureCard: View {
    let task: DownloadTask
    let error: DownloadError
    let vm: AppViewModel
    var compact: Bool = false

    private var hint: String? { FailureAdvice.hint(for: error) }

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: 8) {
            VStack(alignment: compact ? .leading : .center, spacing: 4) {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 11.5, weight: .medium)
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(compact ? .leading : .center)
                    .lineLimit(compact ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let hint {
                    Text(hint)
                        .scaledFont(size: 11)
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
                cardButton(L10n.t("Retry"), "arrow.clockwise",
                           spoken: L10n.t("Retry %@", task.name), prominent: true) { vm.retry(task.id) }
                cardButton(L10n.t("Copy Details"), "doc.on.doc",
                           spoken: L10n.t("Copy error details for %@", task.name)) {
                    vm.copyToPasteboard(FailureAdvice.details(for: task, error: error))
                }
                cardButton(L10n.t("Show Folder"), "folder",
                           spoken: L10n.t("Show the download folder for %@", task.name)) { showFolder() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
        .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.red.opacity(0.25)))
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
                .scaledFont(size: 11, weight: .medium)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(prominent ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                .foregroundStyle(prominent ? Theme.accent : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton(spoken)
    }
}
