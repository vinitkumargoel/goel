import SwiftUI
import GoelCore

/// The file name, editable except for a torrent (whose name is its own), with the extension,
/// size and file count beside it.
struct AddNameSection: View {
    let preview: DownloadPreview
    let sizeText: String
    /// Editable name, extension excluded; nil shows the suggestion read-only.
    var baseName: Binding<String>?

    private var fileExtension: String { FileNameEdit.split(preview.suggestedName).ext }

    private var unitText: String {
        var parts: [String] = []
        if baseName != nil, !fileExtension.isEmpty { parts.append("." + fileExtension) }
        if preview.totalBytes != nil || baseName == nil { parts.append(sizeText) }
        if !preview.files.isEmpty {
            parts.append(preview.files.count == 1 ? L10n.t("%d file", preview.files.count)
                                                  : L10n.t("%d files", preview.files.count))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            AddFieldLabel(L10n.t("File name"))
            if let baseName {
                StudioFocusedField { focus in
                    HStack(spacing: Studio.Space.s) {
                        TextField(L10n.t("File name"), text: baseName)
                            .textFieldStyle(.plain)
                            .studioFont(.bodyStrong)
                            .focused(focus)
                            .accessibilityLabel(L10n.t("File name"))
                            .accessibilityHint(L10n.t("The extension stays the same."))
                        unit
                    }
                }
                AddHelpText(preview.totalBytes == nil
                            ? L10n.t("The extension stays the same.") + " · " + sizeText
                            : L10n.t("The extension stays the same."))
            } else {
                HStack(spacing: Studio.Space.s) {
                    // Not selectable: the displayed text carries invisible break opportunities.
                    FileNameText(preview.suggestedName, lineLimit: 2)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Studio.Space.s)
                    unit
                }
                .padding(.horizontal, Studio.Space.m)
                .frame(minHeight: 36)
                .background(Studio.Palette.well,
                            in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
            }
        }
    }

    private var unit: some View {
        Text(unitText)
            .studioFont(.mono)
            .foregroundStyle(Studio.Palette.ink3)
            .lineLimit(1)
            .fixedSize()
            .help(baseName != nil ? L10n.t("The extension stays the same.") : "")
    }
}

/// "Needs 4.7 GB · 312 GB free", or the warning with a way to pick another folder.
struct AddDiskSpaceRow: View {
    @ObservedObject var model: AddSheetModel
    let preview: DownloadPreview

    var body: some View {
        if let verdict = model.diskVerdict(preview) {
            if verdict.isSufficient {
                AddStatusLine(symbol: "internaldrive", text: DiskSpaceCheck.message(for: verdict))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(DiskSpaceCheck.spokenMessage(for: verdict))
            } else {
                AddCallout(tone: .bad, symbol: "exclamationmark.triangle.fill",
                           message: DiskSpaceCheck.message(for: verdict) + "\n"
                               + L10n.t("There isn’t enough free space on this disk. The download would stop partway."),
                           accessibilityLabel: DiskSpaceCheck.spokenMessage(for: verdict)) {
                    Button(L10n.t("Choose another folder…"), systemImage: "folder") {
                        model.chooseAnotherFolder()
                    }
                    .buttonStyle(.studio(.secondary, size: .small))
                }
            }
        }
    }
}

/// Checksum, mirrors and sign-in cookies, folded in a well (`Advanced options`).
struct AddAdvancedOptions: View {
    @ObservedObject var model: AddSheetModel
    let preview: DownloadPreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.studioStillFrames) private var stillFrames

    private let labelWidth: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            disclosure
            if model.showAdvanced {
                VStack(alignment: .leading, spacing: Studio.Space.m) {
                    if preview.kind != .torrent {
                        row(L10n.t("Checksum")) { AddChecksumField(text: $model.checksumText) }
                    }
                    if preview.kind == .http {
                        row(L10n.t("Mirrors")) { AddMirrorsField(text: $model.mirrorsText) }
                    }
                    if let host = model.previewHost(preview) {
                        row(L10n.t("Sign-in cookies")) {
                            CookieSourcePicker(host: host, source: $model.cookieSource,
                                               pastedCookies: $model.pastedCookies,
                                               capturedCookies: model.capturedCookies,
                                               showsHeader: false)
                        }
                    }
                }
            }
        }
        .padding(Studio.Space.ml)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
            .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
    }

    private var disclosure: some View {
        Button {
            addFlowAnimate(reduceMotion: reduceMotion, stillFrames: stillFrames) { model.showAdvanced.toggle() }
        } label: {
            HStack(spacing: Studio.Space.s) {
                Image(systemName: "chevron.right")
                    .font(StudioFonts.font(.ui, size: 11, weight: 700))
                    .foregroundStyle(Studio.Palette.ink3)
                    .rotationEffect(.degrees(model.showAdvanced ? 90 : 0))
                    .a11yDecorative()
                Text(L10n.t("Advanced options"))
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                Text(model.advancedSummary(preview))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("Advanced options"))
        .accessibilityValue(model.showAdvanced ? L10n.t("Expanded") : L10n.t("Collapsed"))
        .accessibilityHint(model.advancedSummary(preview))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Studio.Space.m) {
            AddFieldLabel(label)
                .frame(width: labelWidth, alignment: .leading)
                .padding(.top, 7)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Expected-checksum entry with live validation of the digest; the algorithm follows its length.
struct AddChecksumField: View {
    @Binding var text: String

    private var isInvalid: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && Checksum.parse(text) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            TextField(L10n.t("MD5, SHA-1, or SHA-256 hex"), text: $text)
                .textFieldStyle(.studio(size: .small, font: .monoBody.weight(400), isInvalid: isInvalid))
                .disableAutocorrection(true)
                .accessibilityLabel(L10n.t("Expected checksum"))
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                if let parsed = Checksum.parse(text) {
                    AddStatusLine(symbol: "checkmark.seal.fill",
                                  text: L10n.t("%@ — verified after the download finishes",
                                               parsed.algorithm.displayName),
                                  tone: .good)
                } else {
                    AddStatusLine(symbol: "exclamationmark.triangle.fill",
                                  text: L10n.t("Not a valid MD5 / SHA-1 / SHA-256 hex digest"),
                                  tone: .warn, tintsText: true)
                }
            }
        }
    }
}

/// Alternative URLs for the same file, one per line.
struct AddMirrorsField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            AddTextArea(text: $text, placeholder: L10n.t("One per line"), height: 56,
                        style: .monoSmall, accessibilityLabel: L10n.t("Mirrors (optional, one per line)"))
            AddHelpText(L10n.t("Alternative URLs for the same file — segments "
                + "spread across them and fail over automatically."))
        }
    }
}

/// The yt-dlp part of the confirm step: its progress, its error, and the preset picker for a page.
struct AddMediaSection: View {
    @ObservedObject var model: AddSheetModel
    let preview: DownloadPreview

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            if let pageURL = model.mediaPageURL(preview) {
                MediaPresetPicker(pageURL: pageURL, maxHeight: model.vm.settings.hlsMaxHeight,
                                  preset: $model.mediaPreset, chosenFormat: $model.chosenFormat,
                                  onListed: { model.pageListsFormats = $0 },
                                  seed: model.mediaListingSeed)
            }
            if model.isResolvingMedia {
                AddLoadingLine(text: L10n.t("Asking yt-dlp…"),
                               accessibilityLabel: L10n.t("Resolving media formats"))
            }
            if let error = model.ytDlpError {
                AddStatusLine(symbol: "exclamationmark.triangle.fill", text: error, tone: .bad, tintsText: true)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.t("Error. %@", error))
            }
        }
    }
}

/// A small spinner and a sentence, for the moments yt-dlp is working.
struct AddLoadingLine: View {
    let text: String
    var accessibilityLabel: String?

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            StudioProgressArc(fraction: nil, diameter: 16, lineWidth: 2) { EmptyView() }
            Text(text)
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink2)
        }
        .padding(.vertical, Studio.Space.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? text)
    }
}
