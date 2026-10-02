import SwiftUI
import AppKit
import QuickLookThumbnailing
import GoelCore

/// Overview's top for a finished download: what the file looks like, when it landed and what to
/// do with it. A missing file says where it was and offers Locate… and Download Again.
struct CompletedHero: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    @State private var thumbnail: NSImage?

    private static let thumbSize = CGSize(width: 360, height: 200)
    private static let previewHeight: CGFloat = 150

    private var filePath: String { task.primaryFilePath }

    private var canPlayInApp: Bool {
        task.isMediaFile && !task.isFileMissing && InAppPlayback.canPlay(URL(fileURLWithPath: filePath))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            preview
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                Text(CompletionSummary.finishedLine(bytes: CompletionSummary.size(of: task),
                                                    completedAt: task.completedAt))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if task.isFileMissing {
                    StudioNote(tone: .warn, symbol: "exclamationmark.triangle.fill",
                               message: L10n.t("The file is no longer where it was saved.") + " "
                                   + L10n.t("It was at %@.", (filePath as NSString).abbreviatingWithTildeInPath))
                        .padding(.top, Studio.Space.xs)
                }
            }
            actions
        }
        .task(id: "\(task.id)|\(filePath)|\(task.isFileMissing)") { await loadThumbnail() }
    }

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
        let kind = StudioArtKind(task: task)
        return ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: Self.previewHeight)
                    .clipped()
            } else {
                StudioArtworkFill(kind: kind)
                    .opacity(task.isFileMissing ? 0.35 : 1)
                StudioFileArtwork(kind: kind, size: .l, isFaded: task.isFileMissing)
            }
            if canPlayInApp, thumbnail != nil {
                Button { vm.playInApp(task) } label: {
                    Image(systemName: "play.fill")
                        .studioFont(.ui, size: 20, weight: 700)
                        .foregroundStyle(Studio.Palette.ink)
                        .frame(width: 52, height: 52)
                        .studioGlass(in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("Play in Goel°"))
                .a11yButton(L10n.t("Play %@ in Goel", task.name))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.previewHeight)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Studio.Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.isFileMissing ? L10n.t("Finished, file missing") : L10n.t("Finished"))
        .accessibilityValue(thumbnail == nil ? "" : L10n.t("Preview of %@", task.name))
    }

    private var actions: some View {
        DetailFlowLayout(spacing: Studio.Space.xs, lineSpacing: Studio.Space.xs) {
            if task.isFileMissing {
                Button(L10n.t("Locate…"), systemImage: "magnifyingglass") { vm.locateMissingFile(task) }
                    .buttonStyle(.studio(.primary, size: .small))
                    .a11yButton(L10n.t("Locate %@", task.name))
                Button(L10n.t("Download Again"), systemImage: "arrow.clockwise") { vm.downloadAgain(task) }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .a11yButton(L10n.t("Download %@ again", task.name))
            } else {
                if canPlayInApp {
                    Button(L10n.t("Play in Goel°"), systemImage: "play.fill") { vm.playInApp(task) }
                        .buttonStyle(.studio(.primary, size: .small))
                        .a11yButton(L10n.t("Play %@ in Goel", task.name))
                }
                Button(L10n.t("Open"), systemImage: "arrow.up.forward.app") { vm.openFile(task) }
                    .buttonStyle(.studio(canPlayInApp ? .secondary : .primary, size: .small))
                    .a11yButton(L10n.t("Open %@", task.name))
                Button(L10n.t("Reveal"), systemImage: "folder") { vm.revealInFinder(task) }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .a11yButton(L10n.t("Show %@ in Finder", task.name))
                CompletedHeroMoreMenu(task: task, vm: vm)
                    .frame(width: 30, height: 27)
                    .background(Studio.Palette.card,
                                in: RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
                        .strokeBorder(Studio.Palette.hairlineStrong, lineWidth: 1))
            }
        }
    }

    /// Quick Look draws what Finder would; anything it can't (or a file that's gone) keeps the
    /// artwork. Only a real thumbnail is accepted, never Quick Look's generic icon.
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
