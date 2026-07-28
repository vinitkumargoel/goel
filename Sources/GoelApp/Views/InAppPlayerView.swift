import SwiftUI
import AVKit
import GoelCore

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
            VideoPlayer(player: player)
                .frame(minWidth: 640, minHeight: 360)
        }
        .frame(width: 760, height: 480)
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}
