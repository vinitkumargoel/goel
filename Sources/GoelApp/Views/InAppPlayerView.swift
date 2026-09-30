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
                    .scaledFont(size: Theme.TextSize.title, weight: .semibold)
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
            .padding(Theme.Space.s)
            if let failure {
                unplayable(failure)
            } else {
                VideoPlayer(player: player)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(item.title)
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
                .scaledFont(size: 34)
                .foregroundStyle(.secondary)
                .a11yDecorative()
            Text(reason)
                .scaledFont(size: Theme.TextSize.meta)
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

/// The Player window's content: whatever ``AppViewModel/playerItem`` holds. Closing the window
/// clears it, so the next Play opens a fresh player instead of resuming a stale one.
struct PlayerWindow: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let item = vm.playerItem {
                InAppPlayerView(item: item) { dismiss() }
                    .id(item.id)
            } else {
                EmptyStateView(systemImage: "play.rectangle", title: L10n.t("Nothing playing"),
                               subtitle: L10n.t("Choose Play on a finished video or audio download."))
                    .frame(minWidth: 480, minHeight: 300)
            }
        }
        .onDisappear { vm.playerItem = nil }
    }
}
