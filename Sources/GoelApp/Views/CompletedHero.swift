import SwiftUI
import AppKit
import QuickLookThumbnailing
import GoelCore

/// The detail panel's top for a finished download: what the file looks like, when it landed,
/// and what to do with it — instead of a 100% ring and two "—" speed cards.
struct CompletedHero: View {
    let task: DownloadTask
    let vm: AppViewModel

    @State private var thumbnail: NSImage?

    private static let thumbSize = CGSize(width: 180, height: 120)

    private var filePath: String { task.primaryFilePath }

    private var canPlayInApp: Bool {
        task.isMediaFile && !task.isFileMissing
            && InAppPlayback.canPlay(URL(fileURLWithPath: filePath))
    }

    var body: some View {
        VStack(spacing: 12) {
            preview
                .padding(.top, 4)

            VStack(spacing: 3) {
                Text(CompletionSummary.finishedLine(bytes: CompletionSummary.size(of: task),
                                                    completedAt: task.completedAt))
                    .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                if task.isFileMissing {
                    Label(L10n.t("The file is no longer where it was saved."),
                          systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(Theme.orange)
                }
            }
            .multilineTextAlignment(.center)

            actions
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .task(id: "\(task.id)|\(filePath)|\(task.isFileMissing)") { await loadThumbnail() }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.fillRest)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                FileTypeIcon(type: task.fileType, size: 56)
            }
        }
        .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .stroke(Theme.hairline))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: task.isFileMissing ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .scaledFont(size: 22, weight: .semibold)
                // The glyph's cut-out shows the window background, so no ink needs picking.
                .foregroundStyle(task.isFileMissing ? Theme.orange : Theme.green)
                .background(Circle().fill(.background))
                .offset(x: 7, y: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.isFileMissing ? L10n.t("Finished, file missing") : L10n.t("Finished"))
        .accessibilityValue(thumbnail == nil ? "" : L10n.t("Preview of %@", task.name))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if task.isFileMissing {
                Button { vm.locateMissingFile(task) } label: {
                    Label(L10n.t("Locate…"), systemImage: "magnifyingglass")
                }
                .buttonStyle(TintedPillButtonStyle(prominent: true))
                .a11yButton(L10n.t("Locate %@", task.name))
                Button { vm.downloadAgain(task) } label: {
                    Label(L10n.t("Download Again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(TintedPillButtonStyle(tint: Color.primary))
                .a11yButton(L10n.t("Download %@ again", task.name))
            } else {
                Button { vm.openFile(task) } label: {
                    Label(L10n.t("Open"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(TintedPillButtonStyle(prominent: true))
                .a11yButton(L10n.t("Open %@", task.name))
                if canPlayInApp {
                    Button { vm.playInApp(task) } label: {
                        Label(L10n.t("Play in Goel°"), systemImage: "play.fill")
                    }
                    .buttonStyle(TintedPillButtonStyle(tint: Color.primary))
                    .a11yButton(L10n.t("Play %@ in Goel", task.name))
                }
                Button { vm.revealInFinder(task) } label: {
                    Label(L10n.t("Reveal"), systemImage: "folder")
                }
                .buttonStyle(TintedPillButtonStyle(tint: Color.primary))
                .a11yButton(L10n.t("Show %@ in Finder", task.name))
            }
        }
    }

    /// Quick Look draws what Finder would; anything it can't (or a file that's gone) keeps the
    /// file-type tile. Only a real thumbnail is accepted, never Quick Look's generic icon.
    private func loadThumbnail() async {
        thumbnail = nil
        guard !task.isFileMissing, FileManager.default.fileExists(atPath: filePath) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: filePath),
                                                   size: Self.thumbSize, scale: scale,
                                                   representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              !Task.isCancelled else { return }
        thumbnail = representation.nsImage
    }
}
