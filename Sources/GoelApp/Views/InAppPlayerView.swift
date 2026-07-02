import SwiftUI
import AVKit

/// A minimal built-in media player: a titled window around AVKit's `VideoPlayer`
/// so a finished download can be watched (or listened to) without leaving the
/// app. Playback stops when the sheet closes so audio never keeps running in the
/// background.
struct InAppPlayerView: View {
    let item: AppViewModel.PlayerItem
    var onClose: () -> Void

    @State private var player: AVPlayer

    init(item: AppViewModel.PlayerItem, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        _player = State(initialValue: AVPlayer(url: item.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.accent)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Done") {
                    player.pause()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            VideoPlayer(player: player)
                .frame(minWidth: 640, minHeight: 360)
        }
        .frame(width: 760, height: 480)
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}
