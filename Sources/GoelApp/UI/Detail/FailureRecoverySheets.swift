import SwiftUI
import GoelCore

/// The failure card's recovery sheets share one shape: a titled Studio sheet, a line of context,
/// the body, and Cancel plus one confirm button (↩ / ⌘↩, Esc cancels).
private struct RecoverySheet<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let confirmTitle: String
    var confirmSymbol: String?
    var confirmDisabled = false
    let onConfirm: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StudioSheet(title: title, symbol: symbol, width: 470) {
            Text(subtitle)
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            content()
        } footer: {
            StudioSheetFooter(onCancel: { dismiss() }, primaryTitle: confirmTitle, primarySymbol: confirmSymbol,
                              primaryEnabled: !confirmDisabled, onPrimary: onConfirm)
        }
    }
}

/// 404/410: paste the link the file lives at now. The download keeps its name and partial file.
struct UpdateLinkSheet: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel
    @State private var link = ""
    @State private var problem: String?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RecoverySheet(
            symbol: "link",
            title: L10n.t("Update Link"),
            subtitle: L10n.t("Paste the new address for “%@”. The download keeps its name and the part already on disk.", task.name),
            confirmTitle: task.status.isFailed ? L10n.t("Update & Retry") : L10n.t("Update"),
            confirmSymbol: task.status.isFailed ? "arrow.clockwise" : nil,
            confirmDisabled: link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working,
            onConfirm: submit
        ) {
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                Text(L10n.t("New link"))
                    .studioFont(.small.weight(600))
                    .foregroundStyle(Studio.Palette.ink2)
                    .accessibilityHidden(true)
                TextField(text: $link, prompt: Text(verbatim: "https://…")) { Text(L10n.t("New link")) }
                    .textFieldStyle(.studio)
                    .studioFont(.monoBody)
                    .accessibilityLabel(L10n.t("New link"))
                    .onSubmit(submit)
            }
            StudioNote(tone: .accent, symbol: "info.circle",
                       message: L10n.t("Goel° resumes only if the new link serves the same file — same size and the same ETag or Last-Modified date. Otherwise it starts again from the beginning, so a changed file is never mixed with the old bytes."))
            if let problem {
                StudioNote(tone: .bad, symbol: "exclamationmark.triangle.fill", message: problem)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .onChange(of: problem) { _, message in
            if let message { A11yAnnouncer.announce(message) }
        }
    }

    private func submit() {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !working else { return }
        working = true
        Task {
            let failure = await vm.updateLink(of: task, to: raw)
            working = false
            if let failure { problem = failure } else { dismiss() }
        }
    }
}

/// 401/403: paste the Cookie header the browser sends. Reuses the Add sheet's picker, so the
/// same scoping and never-persisted rules apply.
struct AttachCookiesSheet: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel
    @State private var source: CookieSource = .manual
    @State private var pasted = ""
    @Environment(\.dismiss) private var dismiss

    private var picker: CookieSourcePicker {
        CookieSourcePicker(host: task.sourceHost, source: $source, pastedCookies: $pasted, capturedCookies: nil)
    }

    var body: some View {
        RecoverySheet(
            symbol: "person.badge.key",
            title: L10n.t("Attach Cookies"),
            subtitle: L10n.t("The server refused “%1$@” without a login. Attach the cookies your browser sends to %2$@.",
                             task.name, task.sourceHost ?? "—"),
            confirmTitle: task.status.isFailed ? L10n.t("Attach & Retry") : L10n.t("Attach"),
            confirmDisabled: picker.sanitizedCookieHeader == nil,
            onConfirm: submit
        ) {
            picker
        }
    }

    private func submit() {
        guard let header = picker.sanitizedCookieHeader else { return }
        vm.attachCookies(header, to: task, retry: true)
        dismiss()
    }
}

/// Disk full: pick a folder with room. Shows what the download still needs next to the free
/// space of the current and the chosen folder, so the choice is informed before anything moves.
struct ChangeFolderSheet: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel
    @State private var chosen: String?
    @Environment(\.dismiss) private var dismiss

    private var remaining: Int64? {
        task.totalBytes.map { max(0, $0 - task.bytesDownloaded) }
    }

    var body: some View {
        RecoverySheet(
            symbol: "folder",
            title: L10n.t("Change Folder"),
            subtitle: L10n.t("Move “%@” to a folder with more room. The part already downloaded moves with it.", task.name),
            confirmTitle: L10n.t("Move & Retry"),
            confirmDisabled: chosen == nil,
            onConfirm: submit
        ) {
            StudioWell(padding: 0) {
                VStack(spacing: 0) {
                    folderRow(L10n.t("Now"), path: task.saveDirectory)
                    if let chosen {
                        StudioDivider()
                        folderRow(L10n.t("New"), path: chosen)
                    }
                }
            }
            HStack(spacing: Studio.Space.m) {
                if let remaining, remaining > 0 {
                    Text(L10n.t("Still to download: %@", remaining.byteString))
                        .studioFont(.mono)
                        .foregroundStyle(Studio.Palette.ink2)
                }
                Spacer(minLength: 0)
                Button(chosen == nil ? L10n.t("Choose Folder…") : L10n.t("Choose Another…"), systemImage: "folder") {
                    if let url = FilePicker.chooseDirectory(prompt: L10n.t("Choose"),
                                                            message: L10n.t("Choose where “%@” should go.", task.name)) {
                        chosen = url.path
                    }
                }
                .buttonStyle(.studio(.secondary, size: .small))
            }
        }
    }

    private func folderRow(_ label: String, path: String) -> some View {
        let free = DiskSpaceCheck.availableCapacity(forFolder: path)
        let short = (path as NSString).abbreviatingWithTildeInPath
        let fits = free.map { free in remaining.map { free >= $0 } ?? true } ?? true
        return HStack(spacing: Studio.Space.s) {
            Text(label)
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.ink3)
                .frame(width: 38, alignment: .leading)
            Text(short)
                .studioFont(.monoBody)
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: Studio.Space.s)
            StudioPill(free.map { L10n.t("%@ free", $0.byteString) } ?? "—", tone: fits ? .good : .bad, showsDot: false)
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, Studio.Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(label, short))
        .accessibilityValue(free.map { L10n.t("%@ free", A11y.bytes($0)) } ?? L10n.t("Free space unknown"))
    }

    private func submit() {
        guard let chosen else { return }
        vm.changeFolder(of: task, to: chosen)
        dismiss()
    }
}
