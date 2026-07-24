import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One playable or viewable file inside the app's `Documents/` container.
///
/// A value type keyed by path so the grid can diff cheaply and so scanning can happen off the
/// main actor and be handed back whole.
struct MediaItem: Identifiable, Hashable, Sendable {
    /// The container-relative path — stable, and what selection is keyed on.
    var id: String
    var url: URL
    var filename: String
    var byteCount: Int64
    var modifiedAt: Date
    var isVideo: Bool
}

/// Walks `Documents/` for things worth showing in the Media tab.
///
/// Runs off the main actor: `FileManager.enumerator` on a container holding a few thousand
/// files takes long enough to drop frames, and the Library tab is entered by a tap.
enum MediaLibraryScanner {

    /// Directory depth the walk will descend. A download tree is shallow; an unbounded walk over
    /// a user-created folder maze is a hang waiting to happen.
    private static let maxDepth = 6

    /// Upper bound on returned items. The grid is a browsing surface, not an exhaustive index —
    /// past this many tiles the answer is search, not more scrolling.
    private static let maxItems = 600

    /// Every file under `root` that QuickLook or AVFoundation can draw, newest first.
    ///
    /// - Parameter root: the container root. Anything the enumerator produces that is not
    ///   actually inside it is dropped — a symlink planted in the container cannot be used to
    ///   surface, and then share out, a file from elsewhere in the sandbox.
    static func scan(root: URL) async -> [MediaItem] {
        await Task.detached(priority: .userInitiated) { () -> [MediaItem] in
            let keys: [URLResourceKey] = [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
            ]
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            let rootDepth = root.standardizedFileURL.pathComponents.count
            var items: [MediaItem] = []

            // `nextObject()` rather than `for…in`: `NSEnumerator`'s iterator is unavailable from
            // an async context, and this walk has to stay off the main actor.
            while let url = walker.nextObject() as? URL {
                if items.count >= maxItems { break }
                if url.standardizedFileURL.pathComponents.count - rootDepth > maxDepth {
                    walker.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let kind = classify(url)
                else { continue }
                guard LibraryPathSafety.isContained(url, within: root) else { continue }

                items.append(
                    MediaItem(
                        id: LibraryPathSafety.relativePath(of: url, within: root) ?? url.lastPathComponent,
                        url: url,
                        filename: url.lastPathComponent,
                        byteCount: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        isVideo: kind == .video
                    )
                )
            }

            return items.sorted { $0.modifiedAt > $1.modifiedAt }
        }.value
    }

    private enum MediaKind { case image, video }

    /// Extension-driven so a file still being written — no readable content yet — still lands in
    /// the grid with a placeholder tile rather than vanishing.
    private static func classify(_ url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }
}

/// The Library's Media tab: a thumbnail grid over the container's images and video.
///
/// Every tile pulls from ``ThumbnailCache``, which is an `actor` — generation is off the main
/// actor by construction, and a tile that scrolls back into view is served from memory or disk
/// instead of decoding the asset again.
struct MediaGrid: View {

    /// Columns in compact width. A count, not a point size, so the tiles breathe with the
    /// device rather than against a hardcoded edge.
    private static let compactColumns = 3
    private static let regularColumns = 5

    let items: [MediaItem]
    /// `true` while the toolbar's **Select** is engaged.
    var isSelecting: Bool
    @Binding var selection: Set<String>
    var onOpen: (MediaItem) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? Self.regularColumns : Self.compactColumns
        return Array(
            repeating: GridItem(.flexible(), spacing: Theme.Metric.gutter),
            count: count
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Metric.gutter) {
                ForEach(items) { item in
                    MediaTile(
                        item: item,
                        isSelecting: isSelecting,
                        isSelected: selection.contains(item.id)
                    ) {
                        if isSelecting {
                            if selection.contains(item.id) {
                                selection.remove(item.id)
                            } else {
                                selection.insert(item.id)
                            }
                        } else {
                            onOpen(item)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, Theme.Metric.gutter)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Color.ground)
    }
}

/// One square tile: cached thumbnail, video badge, filename beneath.
private struct MediaTile: View {

    /// Values `Theme.Metric` does not carry. Named in one place so no bare number appears in a
    /// view body — fold them into `Theme.swift` when it is next open.
    private enum Local {
        /// The mockup's card radius, reused for tiles so the Library reads as one surface.
        static let radius = Theme.Metric.cardRadius
        /// Tile → caption, and the inset of the corner badges. Half the row's vertical padding,
        /// which is the smallest step the rest of the app uses.
        static let tightGap = Theme.Metric.rowVerticalPadding / 2
    }

    let item: MediaItem
    let isSelecting: Bool
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var tileSize: CGSize = .zero

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Local.tightGap) {
                thumbnail
                Text(item.filename)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Color.label2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: Local.radius, style: .continuous)
            .fill(Theme.Color.elev2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.isVideo ? "film" : "photo")
                        .font(.system(size: Theme.Metric.rowIcon / 2, weight: .regular))
                        .foregroundStyle(Theme.Color.label3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Local.radius, style: .continuous))
            .overlay(alignment: .bottomLeading) { videoBadge }
            .overlay(alignment: .topTrailing) { selectionBadge }
            .overlay {
                RoundedRectangle(cornerRadius: Local.radius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.Color.ember : Theme.Color.separator,
                        lineWidth: isSelected ? Theme.Metric.hairline * 4 : Theme.Metric.hairline
                    )
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { tileSize = $0 }
            .task(id: TileRequest(path: item.url.path(percentEncoded: false), size: tileSize)) {
                await load()
            }
    }

    @ViewBuilder
    private var videoBadge: some View {
        if item.isVideo {
            Image(systemName: "play.fill")
                .font(.system(size: Theme.Typo.Size.sectionLabel, weight: .bold))
                .foregroundStyle(.white)
                .padding(Local.tightGap)
                .background(.black.opacity(0.45), in: Circle())
                .padding(Local.tightGap)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: Theme.Typo.Size.statValue, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isSelected ? Theme.Color.ember : Theme.Color.label3)
                .padding(Local.tightGap)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let kind = item.isVideo ? "Video" : "Image"
        return "\(item.filename), \(kind), \(Fmt.bytes(item.byteCount))"
    }

    private func load() async {
        guard tileSize.width > 0, tileSize.height > 0 else { return }
        let rendered = await ThumbnailCache.shared.thumbnail(
            for: item.url,
            size: tileSize,
            scale: displayScale
        )
        guard !Task.isCancelled else { return }
        image = rendered
    }
}

/// The `.task(id:)` identity for a tile: regenerate only when the file or the drawn size
/// changes, never merely because the grid re-laid out.
private struct TileRequest: Equatable {
    var path: String
    var size: CGSize
}

// MARK: - Previews

#Preview("Media grid · light") {
    @Previewable @State var selection: Set<String> = []
    return MediaGrid(
        items: (0..<9).map { index in
            MediaItem(
                id: "sample-\(index)",
                url: URL.documentsDirectory.appending(path: "sample-\(index).mp4"),
                filename: "keynote-2026-4k-hdr-\(index).mp4",
                byteCount: 2_100_000_000,
                modifiedAt: .distantPast,
                isVideo: index.isMultiple(of: 2)
            )
        },
        isSelecting: false,
        selection: $selection,
        onOpen: { _ in }
    )
    .preferredColorScheme(.light)
}
