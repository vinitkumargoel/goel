import SwiftUI
import GoelCore

/// Shared chrome for the failure card's recovery sheets: a title, a line of context, the body,
/// and Cancel plus one confirm button.
private struct RecoverySheet<Content: View>: View {
    let title: String
    let subtitle: String
    let confirmTitle: String
    var confirmDisabled = false
    let onConfirm: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title)
                .scaledFont(size: Theme.TextSize.sheet, weight: .bold)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
            HStack {
                Spacer()
                Button(L10n.t("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmDisabled)
            }
            .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.xl)
        .frame(width: 440)
    }
}

/// 404/410: paste the link the file lives at now. The download keeps its name and partial file.
struct UpdateLinkSheet: View {
    let task: DownloadTask
    let vm: AppViewModel
    @State private var link = ""
    @State private var problem: String?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RecoverySheet(
            title: L10n.t("Update Link"),
            subtitle: L10n.t("Paste the new address for “%@”. The download keeps its name and the part already on disk.", task.name),
            confirmTitle: task.status.isFailed ? L10n.t("Update & Retry") : L10n.t("Update"),
            confirmDisabled: link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working,
            onConfirm: submit
        ) {
            TextField("https://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .scaledFont(size: Theme.TextSize.body, design: .monospaced)
                .accessibilityLabel(L10n.t("New link"))
                .onSubmit(submit)
            Label(L10n.t("Goel° resumes only if the new link serves the same file — same size and the same ETag or Last-Modified date. Otherwise it starts again from the beginning, so a changed file is never mixed with the old bytes."),
                  systemImage: "info.circle")
                .scaledFont(size: Theme.TextSize.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
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
    let vm: AppViewModel
    @State private var source: CookieSource = .manual
    @State private var pasted = ""
    @Environment(\.dismiss) private var dismiss

    private var picker: CookieSourcePicker {
        CookieSourcePicker(host: task.sourceHost, source: $source, pastedCookies: $pasted,
                           capturedCookies: nil)
    }

    var body: some View {
        RecoverySheet(
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
    let vm: AppViewModel
    @State private var chosen: String?
    @Environment(\.dismiss) private var dismiss

    private var remaining: Int64? {
        task.totalBytes.map { max(0, $0 - task.bytesDownloaded) }
    }

    var body: some View {
        RecoverySheet(
            title: L10n.t("Change Folder"),
            subtitle: L10n.t("Move “%@” to a folder with more room. The part already downloaded moves with it.", task.name),
            confirmTitle: L10n.t("Move & Retry"),
            confirmDisabled: chosen == nil,
            onConfirm: submit
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                folderRow(L10n.t("Now"), path: task.saveDirectory)
                if let chosen { folderRow(L10n.t("New"), path: chosen) }
                if let remaining, remaining > 0 {
                    Text(L10n.t("Still to download: %@", remaining.byteString))
                        .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                }
                Button(chosen == nil ? L10n.t("Choose Folder…") : L10n.t("Choose Another…")) {
                    if let url = FilePicker.chooseDirectory(prompt: L10n.t("Choose"),
                                                            message: L10n.t("Choose where “%@” should go.", task.name)) {
                        chosen = url.path
                    }
                }
            }
        }
    }

    private func folderRow(_ label: String, path: String) -> some View {
        let free = DiskSpaceCheck.availableCapacity(forFolder: path)
        let short = (path as NSString).abbreviatingWithTildeInPath
        let fits = free.map { free in remaining.map { free >= $0 } ?? true } ?? true
        return HStack(spacing: Theme.Space.s) {
            Text(label.uppercased())
                .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(short)
                .scaledFont(size: Theme.TextSize.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: Theme.Space.s)
            Text(free.map { L10n.t("%@ free", $0.byteString) } ?? "—")
                .scaledFont(size: Theme.TextSize.meta, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(fits ? Theme.green : Theme.red)
        }
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
