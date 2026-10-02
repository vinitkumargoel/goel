import SwiftUI
import GoelCore

/// A remote item's artwork tile: the Studio file artwork, with the remote glyph (a script reads as
/// a terminal) and a small corner arrow when the item is a symbolic link.
struct SFTPEntryArtwork: View {
    let entry: SFTPEntry
    var size: StudioArtSize = .m

    var body: some View {
        let kind = SFTPFileIcon.artKind(for: entry)
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        ZStack {
            StudioArtworkFill(kind: kind)
                .clipShape(shape)
            shape.strokeBorder(Studio.Palette.artHighlight, lineWidth: 1)
            Image(systemName: SFTPFileIcon.symbol(for: entry))
                .font(StudioFonts.font(.ui, size: size.glyph * 0.82, weight: 600))
                .foregroundStyle(Studio.Palette.artInk)
        }
        .frame(width: size.side, height: size.side)
        .overlay(alignment: .bottomTrailing) {
            if entry.isSymlink { SFTPSymlinkBadge(entry: entry, size: size) }
        }
        .accessibilityHidden(true)
    }
}

/// The alias arrow in the artwork's corner, with the link target as its tooltip.
struct SFTPSymlinkBadge: View {
    let entry: SFTPEntry
    var size: StudioArtSize = .m

    var body: some View {
        let side: CGFloat = size == .xs ? 11 : size == .s ? 13 : 16
        Image(systemName: "arrow.up.forward")
            .font(StudioFonts.font(.ui, size: side * 0.55, weight: 800))
            .foregroundStyle(Studio.Palette.ink)
            .frame(width: side, height: side)
            .background(Studio.Palette.card, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Studio.Palette.hairlineStrong, lineWidth: 1))
            .offset(x: 3, y: 3)
            .help(entry.linkTarget.isEmpty ? L10n.t("Symbolic link")
                                           : L10n.t("Symbolic link to %@", entry.linkTarget))
    }
}

/// A transfer's artwork: the moved item's family, faded while it waits or is paused.
struct SFTPTransferArtwork: View {
    let transfer: SFTPTransfer
    var size: StudioArtSize = .s

    var body: some View {
        StudioFileArtwork(kind: transfer.artKind, size: size,
                          isFaded: transfer.state == .paused || transfer.state == .cancelled)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: transfer.arrowGlyph)
                    .font(StudioFonts.font(.ui, size: size == .xs ? 7 : 8.5, weight: 800))
                    .foregroundStyle(Studio.Palette.onAccent)
                    .frame(width: size == .xs ? 12 : 15, height: size == .xs ? 12 : 15)
                    .background(transfer.studioDirectionColor, in: Circle())
                    .overlay(Circle().strokeBorder(Studio.Palette.card, lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }
            .accessibilityHidden(true)
    }
}
