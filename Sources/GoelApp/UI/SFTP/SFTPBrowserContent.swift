import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The folder itself: a list in a card or a grid of tiles, the marquee, the drop target, the
/// empty and no-match states, and the keyboard target behind it all.
extension SFTPBrowserView {

    var entryArea: some View {
        ScrollViewReader { proxy in
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: Studio.Space.m) {
                        if isGrid { gridBody } else { listBody }
                        if !visibleEntries.isEmpty { dropStrip }
                    }
                    .padding(.horizontal, Studio.Space.gutter)
                    .padding(.top, Studio.Space.xxs)
                    .padding(.bottom, Studio.Space.xl)
                    // Stretch to at least the viewport so the area below a short
                    // listing still starts a marquee / clears the selection.
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                    .background(marqueeCatcher)
                    .overlay(alignment: .topLeading) { marqueeOverlay }
                    .coordinateSpace(name: Self.listSpace)
                    .onPreferenceChange(SFTPEntryFramePreference.self) { [box = entryFrames] value in
                        box.frames = value
                    }
                }
            }
            .overlay { emptyOrLoading }
            .overlay { if dropTargeted && folderDropTarget == nil { dropHint } }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                handleUploadDrop(providers)
            }
            .contextMenu { emptyAreaMenu }
            .background { keyTarget(proxy) }
            // A click anywhere in the folder hands the keyboard to the list.
            .simultaneousGesture(TapGesture().onEnded { listFocused = true })
        }
    }

    /// The keyboard target sits behind the content: a focusable ancestor would make every button
    /// inside read `isFocused` and draw its ring.
    private func keyTarget(_ proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress { press in handleKey(press, proxy: proxy) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var emptyOrLoading: some View {
        if visibleEntries.isEmpty {
            if model.isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .tint(Studio.Palette.accent)
                    .accessibilityLabel(L10n.t("Loading folder"))
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        Group {
            if isFiltering {
                StudioEmptyState(symbol: "magnifyingglass", title: L10n.t("No matches"),
                                 message: L10n.t("Nothing here matches “%@”.", searchText)) {
                    Button(L10n.t("Clear filter")) { searchText = "" }
                        .buttonStyle(.studio(.secondary))
                }
            } else {
                StudioEmptyState(symbol: "tray", title: L10n.t("This folder is empty"),
                                 message: L10n.t("Drop files or folders here to upload")) {
                    Button(L10n.t("Upload…"), systemImage: "arrow.up.doc") { chooseUploadItems() }
                        .buttonStyle(.studio(.primary))
                    Button(L10n.t("New Folder"), systemImage: "folder.badge.plus") { requestNewFolder() }
                        .buttonStyle(.studio(.secondary))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The standing hint under the files (`.drop`), naming where an upload lands.
    private var dropStrip: some View {
        HStack(spacing: Studio.Space.sm) {
            Image(systemName: "arrow.up.doc")
                .font(StudioFonts.font(.ui, size: 14, weight: 650))
            Text(L10n.t("Drop files or folders here to upload to %@", model.displayPath))
                .studioFont(.small.weight(550))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Studio.Palette.accent)
        .padding(.horizontal, Studio.Space.ml)
        .padding(.vertical, Studio.Space.ml)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Studio.Palette.accentSoft.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
            .strokeBorder(Studio.Palette.accentLine, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .accessibilityHidden(true)
    }

    /// While files are dragged over the folder (not over one of its subfolders).
    private var dropHint: some View {
        ZStack {
            Studio.Palette.scrim.opacity(0.35)
            VStack(spacing: Studio.Space.sm) {
                Image(systemName: "arrow.up.doc")
                    .font(StudioFonts.font(.ui, size: 30, weight: 600))
                Text(L10n.t("Upload to %@", model.displayPath))
                    .studioFont(.title3)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Studio.Palette.accent)
            .padding(Studio.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Studio.Palette.card, in: RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
                .strokeBorder(Studio.Palette.accentLine, style: StrokeStyle(lineWidth: 3, dash: [8, 6])))
            .padding(Studio.Space.xl)
        }
        .allowsHitTesting(false)
        .a11yDecorative()
    }

    // MARK: - Marquee

    /// Sits behind the rows: only clicks and drags on empty space reach it, so a
    /// drag on a row keeps its file-drag meaning while empty space draws a marquee.
    private var marqueeCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { selection.removeAll() }
            .gesture(marqueeGesture)
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if marqueeBase == nil {
                    // Shift or command extends the existing selection, Finder-style.
                    let mods = NSEvent.modifierFlags
                    marqueeBase = mods.contains(.shift) || mods.contains(.command) ? selection : []
                    listFocused = true
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                marqueeRect = rect
                let hit = entryFrames.frames.filter { $0.value.intersects(rect) }.map(\.key)
                let next = (marqueeBase ?? []).union(hit)
                if next != selection { selection = next }
            }
            .onEnded { _ in
                marqueeRect = nil
                marqueeBase = nil
            }
    }

    @ViewBuilder private var marqueeOverlay: some View {
        if let rect = marqueeRect {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Studio.Palette.accentSoft)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Studio.Palette.accentLine, lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var listBody: some View {
        if !visibleEntries.isEmpty {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { StudioDivider().padding(.leading, 52) }
                        entryInteractions(
                            SFTPEntryRow(entry: entry, isSelected: selection.contains(entry.id),
                                         isHovered: hoveredEntry == entry.id,
                                         isDropTarget: folderDropTarget == entry.id,
                                         activity: activity(for: entry)),
                            entry: entry)
                            .id(entry.id)
                    }
                } header: {
                    SFTPColumnHeader(sortKey: sortKey, ascending: sortAscending, onSort: setSort)
                }
            }
            .padding(.bottom, Studio.Space.xs)
            .studioSurface(.card, radius: Studio.Radius.card, elevation: .card)
        }
    }

    // MARK: - Grid

    private var gridBody: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Studio.Space.m)],
                  spacing: Studio.Space.m) {
            ForEach(visibleEntries) { entry in
                entryInteractions(
                    SFTPEntryTile(entry: entry, isSelected: selection.contains(entry.id),
                                  isHovered: hoveredEntry == entry.id,
                                  isDropTarget: folderDropTarget == entry.id,
                                  activity: activity(for: entry)),
                    entry: entry)
                    .id(entry.id)
            }
        }
        .padding(.top, 2)
    }

    /// A transfer of this very item, still moving or paused: its tile and row show the progress.
    func activity(for entry: SFTPEntry) -> SFTPTransfer? {
        let remote = SFTPBrowserModel.join(model.path, entry.name)
        return myTransfers.first { $0.remotePath == remote && $0.occupiesDestination && $0.direction != .remoteCopy }
    }

    // MARK: - Interactions

    /// Selection, hover, drag and drop shared by list rows and grid tiles.
    func entryInteractions<V: View>(_ content: V, entry: SFTPEntry) -> some View {
        let selected = selection.contains(entry.id)
        let traits: AccessibilityTraits = selected ? [.isButton, .isSelected] : .isButton
        let hint: String = entry.isDirectory ? L10n.t("Activate to open.") : L10n.t("Activate to select.")
        return content
            .a11yGroup(label: entryLabel(entry), value: entryValue(entry), hint: hint)
            .accessibilityAddTraits(traits)
            .accessibilityAction { primaryAction(entry) }
            .contentShape(Rectangle())
            .background(GeometryReader { g in
                Color.clear.preference(key: SFTPEntryFramePreference.self,
                                       value: [entry.id: g.frame(in: .named(Self.listSpace))])
            })
            .onHover { inside in updateHover(entry.id, inside: inside) }
            .onTapGesture(count: 2) { primaryAction(entry) }
            .onTapGesture { handleClick(entry) }
            .modifier(SFTPEntryDragDrop(entry: entry, model: model,
                                        dropTarget: folderDropBinding(entry.id),
                                        onDrop: { providers in handleUploadDrop(providers, into: entry) }))
            .contextMenu { rowMenu(entry) }
    }

    private func entryLabel(_ entry: SFTPEntry) -> String {
        L10n.t("%1$@, %2$@", SFTPFileIcon.spokenKind(for: entry), entry.name)
    }

    private func entryValue(_ entry: SFTPEntry) -> String {
        A11y.sentence(
            entry.isDirectory ? nil : A11y.bytes(entry.size),
            entry.modified.map { L10n.t("modified %@", $0.formatted(date: .abbreviated, time: .shortened)) },
            activity(for: entry).map { A11y.sentence(L10n.t($0.activityLabel), A11y.percent($0.fraction)) })
    }

    /// Clear only if this row still owns the highlight — neighbours race on leave events.
    private func updateHover(_ id: SFTPEntry.ID, inside: Bool) {
        if inside { hoveredEntry = id }
        else if hoveredEntry == id { hoveredEntry = nil }
    }

    private func folderDropBinding(_ id: SFTPEntry.ID) -> Binding<Bool> {
        Binding(
            get: { folderDropTarget == id },
            set: { folderDropTarget = $0 ? id : (folderDropTarget == id ? nil : folderDropTarget) }
        )
    }
}

/// Files drag out (the model streams them to a temp file on demand); folders take drops.
private struct SFTPEntryDragDrop: ViewModifier {
    let entry: SFTPEntry
    let model: SFTPBrowserModel
    let dropTarget: Binding<Bool>
    let onDrop: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if entry.isDirectory {
            content.onDrop(of: [.fileURL], isTargeted: dropTarget, perform: onDrop)
        } else {
            content.onDrag { model.fileProvider(for: entry) }
        }
    }
}

/// Visible rows report their frames (in the list's coordinate space) so the
/// marquee drag can hit-test the selection rectangle against them.
struct SFTPEntryFramePreference: PreferenceKey {
    static let defaultValue: [SFTPEntry.ID: CGRect] = [:]
    static func reduce(value: inout [SFTPEntry.ID: CGRect],
                       nextValue: () -> [SFTPEntry.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
