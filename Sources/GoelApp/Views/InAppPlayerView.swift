import AppKit
import SwiftUI
import AVKit
import GoelCore

struct InAppPlayerView: View {
    let item: AppViewModel.PlayerItem
    var onClose: () -> Void

    @State private var player: AVPlayer
    @State private var failure: String?

    init(item: AppViewModel.PlayerItem, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        _player = State(initialValue: AVPlayer(url: item.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.accent)
                    .a11yDecorative()
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(L10n.t("Now playing, %@", item.title))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.t("Done")) {
                    player.pause()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L10n.t("Close player"))
            }
            .padding(10)
            if let failure {
                unplayable(failure)
            } else {
                VideoPlayer(player: player)
                    .frame(minWidth: 640, minHeight: 360)
            }
        }
        .frame(width: 760, height: 480)
        .onAppear { player.play() }
        .onDisappear { player.pause() }
        // AVPlayer reports a file it cannot decode by playing nothing, so the reason has to be
        // asked for. The container was already cleared; this catches the codecs inside it.
        .task {
            guard let asset = player.currentItem?.asset else { return }
            do {
                guard try await asset.load(.isPlayable) == false else { return }
                failure = L10n.t("This file’s video or audio track uses a codec macOS can’t decode.")
            } catch {
                failure = error.localizedDescription
            }
            player.pause()
        }
    }

    @ViewBuilder
    private func unplayable(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "play.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .a11yDecorative()
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(L10n.t("Open in Default Player")) {
                NSWorkspace.shared.open(item.url)
                onClose()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
