import SwiftUI
import GoelCore

/// The confirm step's file list; for a torrent each file can be ticked off.
struct AddSheetFileList: View {
    let files: [TransferFile]
    let selectable: Bool
    @Binding var deselectedFileIDs: Set<Int>

    var body: some View {
        let selectedCount = files.count - files.filter { deselectedFileIDs.contains($0.id) }.count
        let selectedBytes = files.filter { !deselectedFileIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.length }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.t("Files")).scaledFont(size: Theme.TextSize.body, weight: .semibold).foregroundStyle(.secondary)
                Spacer()
                if selectable {
                    Text(L10n.t("%1$d of %2$d · %3$@", selectedCount, files.count, selectedBytes.byteString))
                        .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { file in
                        row(file)
                        if file.id != files.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(files.count) * 28 + 4, 170))
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        }
    }

    private func row(_ file: TransferFile) -> some View {
        let wanted = !deselectedFileIDs.contains(file.id)
        let name = (file.path as NSString).lastPathComponent
        return HStack(spacing: 8) {
            if selectable {
                Button {
                    if wanted { deselectedFileIDs.insert(file.id) }
                    else { deselectedFileIDs.remove(file.id) }
                } label: {
                    Image(systemName: wanted ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(wanted ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .a11yButton(wanted ? L10n.t("Skip %@", name) : L10n.t("Download %@", name))
                .accessibilityValue(wanted ? L10n.t("Included") : L10n.t("Skipped"))
            } else {
                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .a11yDecorative()
            }
            Text(name)
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(wanted ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(file.length.byteString)
                .scaledFont(size: Theme.TextSize.meta, design: .monospaced)
                .foregroundStyle(.secondary)
                .accessibilityLabel(A11y.bytes(file.length))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
}

/// Expected-checksum entry with live validation of the digest.
struct AddSheetChecksumField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Checksum (optional)"))
                .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                .foregroundStyle(.secondary)
            TextField(L10n.t("MD5, SHA-1, or SHA-256 hex"), text: $text)
                .accessibilityLabel(L10n.t("Expected checksum"))
                .textFieldStyle(.roundedBorder)
                .scaledFont(size: Theme.TextSize.body, design: .monospaced)
                .disableAutocorrection(true)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                if let parsed = Checksum.parse(text) {
                    Label(L10n.t("%@ — verified after the download finishes", parsed.algorithm.displayName),
                          systemImage: "checkmark.seal.fill")
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(Theme.green)
                } else {
                    Label(L10n.t("Not a valid MD5 / SHA-1 / SHA-256 hex digest"),
                          systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(Theme.orange)
                }
            }
        }
    }
}

/// Alternative URLs for the same file, one per line.
struct AddSheetMirrorsField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Mirrors (optional, one per line)"))
                .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .scaledFont(size: Theme.TextSize.meta, design: .monospaced)
                .frame(height: 44)
                .padding(4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            Text(L10n.t("Alternative URLs for the same file — segments spread across them and fail over automatically."))
                .scaledFont(size: Theme.TextSize.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The protocol pill beside the previewed name.
struct AddSheetKindBadge: View {
    let kind: DownloadKind

    var body: some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .http: return ("HTTP", Theme.accent)
            case .torrent: return ("BT", Theme.green)
            case .hls: return ("HLS", Theme.orange)
            case .ftp: return ("FTP", Theme.teal)
            case .sftp: return ("SFTP", Theme.indigo)
            }
        }()
        Text(label)
            .scaledFont(size: Theme.TextSize.caption, weight: .bold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
