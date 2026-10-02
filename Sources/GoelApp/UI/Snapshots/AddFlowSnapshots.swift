#if DEBUG
import SwiftUI
import GoelCore

/// The AddFlow area's snapshots: every step and state of the Add sheet, the media pickers, the
/// review step and the Link Grabber. Sample data lives in `UI/AddFlow/AddFlowSnapshotSamples.swift`.
/// Render with `GoelDownloader --studio-snapshots <outdir> --only add.`
@MainActor
enum AddFlowSnapshots {
    static var entries: [StudioSnapshotEntry] {
        inputEntries + confirmEntries + mediaEntries + reviewEntries + grabberEntries
    }

    // MARK: Input & resolving

    private static var inputEntries: [StudioSnapshotEntry] {
        [
            entry("add.input", sheetWidth: 580) { model in
                AddDownloadSheet(configure: { flow in
                    flow.text = AddFlowSamples.pastedLines
                    flow.pastedText = AddFlowSamples.pastedLines
                })
                .studioSampleEnvironment(model)
            },
            entry("add.input.empty", sheetWidth: 580) { model in
                AddDownloadSheet(configure: { _ in }).studioSampleEnvironment(model)
            },
            entry("add.input.error", sheetWidth: 580) { model in
                AddDownloadSheet(configure: { flow in
                    flow.text = "releases.ubuntu.com is great"
                    flow.inputError = L10n.t("Enter a valid URL, magnet, or .m3u8 link.")
                })
                .studioSampleEnvironment(model)
            },
            entry("add.input.drop", sheetWidth: 580) { model in
                AddInputStep(model: AddSheetModel(vm: model, capturedCookies: nil), isDropTargeted: true)
                    .frame(width: 580)
                    .background(Studio.Palette.sheet)
                    .studioSampleEnvironment(model)
            },
            entry("add.resolving", sheetWidth: 580) { model in
                AddDownloadSheet(configure: { flow in
                    flow.text = AddFlowSamples.isoURL
                    flow.phase = .resolving
                })
                .studioSampleEnvironment(model)
            },
        ]
    }

    // MARK: Confirm

    private static var confirmEntries: [StudioSnapshotEntry] {
        [
            confirm("add.confirm", preview: AddFlowSamples.isoPreview),
            confirm("add.confirm.duplicate", preview: AddFlowSamples.duplicatePreview),
            confirm("add.confirm.advanced", preview: AddFlowSamples.isoPreview, captured: AddFlowSamples.cookies) { flow in
                flow.checksumText = "c2e6f4dc37ac944e2ed507f87c6188dd4f7ac0dc6f6a39bdbd8b12a5a2b23f1b"
                flow.mirrorsText = "https://mirror.example.org/ubuntu/24.04.1/ubuntu-24.04.1-live-server-amd64.iso"
                flow.cookieSource = .browser
            },
            confirm("add.confirm.cookies", preview: AddFlowSamples.isoPreview) { flow in
                flow.checksumText = "not-a-digest"
                flow.cookieSource = .manual
                flow.pastedCookies = "sid=abc; csrf=def; theme=dark"
            },
            confirm("add.confirm.torrent", preview: AddFlowSamples.torrentPreview) { flow in
                flow.deselectedFileIDs = [2]
            },
            confirm("add.confirm.torrent.none", preview: AddFlowSamples.torrentPreview) { flow in
                flow.deselectedFileIDs = [0, 1, 2, 3]
            },
            confirm("add.confirm.unreachable", preview: AddFlowSamples.unreachablePreview),
            confirm("add.confirm.lowspace", preview: AddFlowSamples.isoPreview) { flow in
                flow.refreshesFreeSpace = false
                flow.freeBytes = 1_200_000_000
            },
        ]
    }

    // MARK: Media & playlist

    private static var mediaEntries: [StudioSnapshotEntry] {
        [
            confirm("add.confirm.media", preview: AddFlowSamples.videoPagePreview) { flow in
                flow.mediaListingSeed = .loaded(AddFlowSamples.formats)
            },
            confirm("add.confirm.media.loading", preview: AddFlowSamples.videoPagePreview) { flow in
                flow.mediaListingSeed = .loading
            },
            confirm("add.confirm.media.failed", preview: AddFlowSamples.videoPagePreview) { flow in
                flow.mediaListingSeed = .failed("ERROR: [vimeo] 76979871: This video is private.")
            },
            confirm("add.confirm.media.resolving", preview: AddFlowSamples.videoPagePreview) { flow in
                flow.mediaListingSeed = .loaded(AddFlowSamples.formats)
                flow.isResolvingMedia = true
            },
            confirm("add.confirm.media.error", preview: AddFlowSamples.videoPagePreview) { flow in
                flow.mediaListingSeed = .loaded(AddFlowSamples.formats)
                flow.ytDlpError = "yt-dlp timed out after 60 seconds."
            },
            entry("add.formats", sheetWidth: 500) { model in
                formatCard(MediaFormatPicker(pageURL: AddFlowSamples.pageURL, seed: .loaded(AddFlowSamples.formats),
                                             showsSeparateTracks: true) { _ in })
                    .studioSampleEnvironment(model)
            },
            entry("add.formats.loading", sheetWidth: 500) { model in
                formatCard(MediaFormatPicker(pageURL: AddFlowSamples.pageURL, seed: .loading) { _ in })
                    .studioSampleEnvironment(model)
            },
            entry("add.formats.failed", sheetWidth: 500) { model in
                formatCard(MediaFormatPicker(pageURL: AddFlowSamples.pageURL,
                                             seed: .failed("yt-dlp isn’t allowed to run: it is quarantined.")) { _ in })
                    .studioSampleEnvironment(model)
            },
            playlist("add.playlist", seed: .loaded(AddFlowSamples.playlist)),
            playlist("add.playlist.loading", seed: .loading),
            playlist("add.playlist.failed", seed: .failed(L10n.t("That link is a single video, not a playlist."))),
        ]
    }

    // MARK: Review

    private static var reviewEntries: [StudioSnapshotEntry] {
        [
            entry("add.review", sheetWidth: 760) { model in
                AddDownloadSheet(configure: { flow in
                    flow.text = AddFlowSamples.reviewLines
                    flow.reviewSeed = AddFlowSamples.reviewItems(model)
                    flow.phase = .review(AddFlowSamples.reviewLines)
                })
                .studioSampleEnvironment(model)
            },
        ]
    }

    // MARK: Link Grabber

    private static var grabberEntries: [StudioSnapshotEntry] {
        let page = "https://www.blender.org/download/demo-files/"
        let links = AddFlowSamples.grabbedLinks
        let archives = Set(links.filter { $0.category == .archive }.prefix(5).map(\.url))
        return [
            grabber("add.grabber", seed: .init(pageText: page, pastedFromClipboard: true)),
            grabber("add.grabber.results",
                    seed: .init(pageText: page, links: links, selected: archives, totalFound: links.count)),
            grabber("add.grabber.filtered",
                    seed: .init(pageText: page, links: links, selected: archives,
                                categoryFilter: .archive, totalFound: 640)),
            grabber("add.grabber.fetching", seed: .init(pageText: page, isFetching: true)),
            grabber("add.grabber.error.url",
                    seed: .init(pageText: "blender.org/download", fetchError: L10n.t("Enter a full http(s) page URL."))),
            grabber("add.grabber.error.large",
                    seed: .init(pageText: page, fetchError: L10n.t("That page is too large to scan."))),
            grabber("add.grabber.error.none",
                    seed: .init(pageText: page, fetchError: L10n.t("No downloadable links found on that page."))),
            grabber("add.grabber.error.load",
                    seed: .init(pageText: page,
                                fetchError: L10n.t("The page couldn’t be loaded: %@", "403 Forbidden"))),
            entry("add.grabber.review", sheetWidth: 760) { model in
                let picked = links.prefix(6).map(\.url)
                LinkGrabberSheet(seed: .init(pageText: page, links: links, selected: Set(picked), totalFound: 640,
                                             reviewText: picked.joined(separator: "\n"),
                                             reviewItems: AddFlowSamples.items(model, from: picked)))
                    .studioSampleEnvironment(model)
            },
        ]
    }

    // MARK: Builders

    /// The sheet floated on the canvas like the mockup's artboards: 22 pt corners, floating shadow.
    private static func entry<Content: View>(_ name: String, sheetWidth: CGFloat, height: CGFloat? = nil,
                                             @ViewBuilder _ content: @escaping (AppViewModel) -> Content) -> StudioSnapshotEntry {
        StudioSnapshotEntry(name, width: sheetWidth + 48, height: height) { context in
            AddFlowSheetFrame { content(context.model) }
        }
    }

    private static func confirm(_ name: String, preview: DownloadPreview, captured: String? = nil,
                                _ setUp: @escaping (AddSheetModel) -> Void = { _ in }) -> StudioSnapshotEntry {
        entry(name, sheetWidth: 620) { model in
            AddDownloadSheet(capturedCookies: captured, configure: { flow in
                flow.text = preview.source.locator
                flow.phase = .confirm(preview)
                setUp(flow)
            })
            .studioSampleEnvironment(model)
        }
    }

    private static func playlist(_ name: String, seed: AddListingSeed<PlaylistExpansion>) -> StudioSnapshotEntry {
        entry(name, sheetWidth: 580) { model in
            AddDownloadSheet(configure: { flow in
                flow.text = AddFlowSamples.playlistURL.absoluteString
                flow.playlistSeed = seed
                flow.phase = .playlist(AddFlowSamples.playlistURL)
            })
            .studioSampleEnvironment(model)
        }
    }

    private static func grabber(_ name: String, seed: LinkGrabberSheet.Seed) -> StudioSnapshotEntry {
        entry(name, sheetWidth: 720) { model in
            LinkGrabberSheet(seed: seed).studioSampleEnvironment(model)
        }
    }

    private static func formatCard<Content: View>(_ picker: Content) -> some View {
        picker
            .padding(Studio.Space.xl)
            .frame(width: 500)
            .background(Studio.Palette.sheet)
    }
}

private struct AddFlowSheetFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.sheet, style: .continuous)
        content()
            .clipShape(shape)
            .overlay(shape.strokeBorder(Studio.Palette.cardEdge, lineWidth: 1))
            .background(shape.fill(Studio.Palette.sheet).studioElevation(.floating))
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
#endif
