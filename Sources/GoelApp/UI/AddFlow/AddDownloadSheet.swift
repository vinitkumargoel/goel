import SwiftUI
import GoelCore

/// The Add download sheet: links in, a preview, then options and start. Several links go to the
/// shared review step, a playlist to its checklist. Presented by RootView.
struct AddDownloadSheet: View {
    @EnvironmentObject private var vm: AppViewModel

    var capturedCookies: String? = nil
    /// Snapshot seam: sets the model up before the first frame and skips the clipboard prefill.
    var configure: ((AddSheetModel) -> Void)? = nil

    var body: some View {
        AddDownloadFlow(vm: vm, capturedCookies: capturedCookies, configure: configure)
    }
}

private struct AddDownloadFlow: View {
    @ObservedObject private var vm: AppViewModel
    @StateObject private var model: AddSheetModel
    @Environment(\.dismiss) private var dismiss
    private let isSeeded: Bool

    init(vm: AppViewModel, capturedCookies: String?, configure: ((AddSheetModel) -> Void)?) {
        _vm = ObservedObject(wrappedValue: vm)
        isSeeded = configure != nil
        _model = StateObject(wrappedValue: {
            let model = AddSheetModel(vm: vm, capturedCookies: capturedCookies)
            configure?(model)
            return model
        }())
    }

    var body: some View {
        phaseContent
            .frame(width: width)
            .background(Studio.Palette.sheet)
            .onAppear {
                model.finish = { dismiss() }
                if !isSeeded { model.autoPasteFromClipboard() }
            }
            .onChange(of: vm.addSheetPrefill) { _, new in if new != nil { model.consumePrefill() } }
            // Without this cancel the yt-dlp subprocess keeps running headless after the sheet closes.
            .onDisappear { model.cancelResolve() }
    }

    private var width: CGFloat {
        switch model.phase {
        case .input, .resolving, .playlist: return 580
        case .confirm: return 620
        case .review: return 760
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .input:
            AddInputStep(model: model)
        case .resolving:
            AddResolvingStep(model: model)
        case .confirm(let preview):
            AddConfirmStep(model: model, preview: preview)
        case .review(let lines):
            LinkReviewView(title: model.reviewTitle(lines), text: lines, seed: model.reviewSeed,
                           back: { model.phase = .input }, done: { dismiss() })
        case .playlist(let url):
            PlaylistChecklistView(
                playlistURL: url,
                sheetActions: .init(
                    back: { model.phase = .input },
                    singleVideo: { model.resolveSingleVideo() },
                    cancel: { dismiss() }),
                maxHeight: vm.settings.hlsMaxHeight,
                seed: model.playlistSeed
            ) { items, preset in
                model.addPlaylist(items, preset: preset)
            }
        }
    }
}
