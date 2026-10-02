import AppKit
import SwiftUI
import AVKit
import GoelCore

/// The in-app player: a title bar ("Now playing, …" and Done) over the system video player. A file
/// AVFoundation can't decode gets a card that hands it to the default player instead.
struct InAppPlayerView: View {
    let item: AppViewModel.PlayerItem
    var onClose: () -> Void

    @State private var player: AVPlayer
    @State private var failure: String?

    /// `failure` is for previews and snapshots; the app learns it from the asset.
    init(item: AppViewModel.PlayerItem, failure: String? = nil, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        _player = State(initialValue: AVPlayer(url: item.url))
        _failure = State(initialValue: failure)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failure {
                unplayable(failure)
            } else {
                VideoPlayer(player: player)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .studioWindowBackground()
        .navigationTitle(item.title)
        .onAppear { if failure == nil { player.play() } }
        .onDisappear { player.pause() }
        // AVPlayer reports a file it cannot decode by playing nothing, so the reason has to be
        // asked for. The container was already cleared; this catches the codecs inside it.
        .task {
            guard failure == nil, let asset = player.currentItem?.asset else { return }
            do {
                guard try await asset.load(.isPlayable) == false else { return }
                failure = L10n.t("This file’s video or audio track uses a codec macOS can’t decode.")
            } catch {
                failure = error.localizedDescription
            }
            player.pause()
        }
    }

    private var header: some View {
        HStack(spacing: Studio.Space.s) {
            Image(systemName: "play.rectangle.fill")
                .font(StudioFonts.font(.ui, size: 14, weight: 650))
                .foregroundStyle(Studio.Palette.accent)
                .accessibilityHidden(true)
            Text(item.title)
                .studioFont(.bodyStrong.size(13.5))
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(L10n.t("Now playing, %@", item.title))
                .accessibilityAddTraits(.isHeader)
                .help(item.title)
            Spacer(minLength: Studio.Space.s)
            Button(L10n.t("Done")) {
                player.pause()
                onClose()
            }
            .buttonStyle(.studio(.secondary, size: .small))
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(L10n.t("Close player"))
        }
        .windowsToolbarChrome()
    }

    private func unplayable(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            HStack(spacing: Studio.Space.s) {
                Image(systemName: "film")
                    .font(StudioFonts.font(.ui, size: 17, weight: 650))
                    .foregroundStyle(Studio.Palette.warn)
                    .accessibilityHidden(true)
                Text(L10n.t("Can’t play this file here"))
                    .studioFont(.title3)
                    .foregroundStyle(Studio.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(reason)
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.t("Open in Default Player"), systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(item.url)
                onClose()
            }
            .buttonStyle(.studio(.primary, size: .small))
        }
        .padding(Studio.Space.xl)
        .frame(width: 340, alignment: .leading)
        .studioSurface(.sheet, radius: Studio.Radius.card, elevation: .floating)
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
                StudioEmptyState(symbol: "play.rectangle", title: L10n.t("Nothing playing"),
                                 message: L10n.t("Choose Play on a finished video or audio download.")) {
                    EmptyView()
                }
                .frame(minWidth: 480, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                .studioWindowBackground()
            }
        }
        .onDisappear { vm.playerItem = nil }
    }
}
