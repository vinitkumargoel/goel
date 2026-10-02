#if DEBUG
import SwiftUI
import GoelCore

/// The design-system gallery: every token and component, light and dark.
/// `GoelDownloader --studio-snapshots /tmp/studio --only ds.`
@MainActor
enum DesignSystemSnapshots {
    static var entries: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("ds.gallery", width: 1240) { _ in DesignSystemGallery() },
            StudioSnapshotEntry("ds.tokens", width: 1240) { _ in GallerySection.tokens },
            StudioSnapshotEntry("ds.type", width: 1240) { _ in GallerySection.type },
            StudioSnapshotEntry("ds.artwork", width: 1240) { _ in GallerySection.artwork },
            StudioSnapshotEntry("ds.progress", width: 1240) { _ in GallerySection.progress },
            StudioSnapshotEntry("ds.controls", width: 1240) { _ in GallerySection.controls },
            StudioSnapshotEntry("ds.surfaces", width: 1240) { _ in GallerySection.surfaces },
            StudioSnapshotEntry("ds.navigation", width: 1240) { context in
                GallerySection.navigation(model: context.model)
            },
        ]
    }
}

/// Everything at once, for a quick look.
struct DesignSystemGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GallerySection.tokens
            GallerySection.type
            GallerySection.artwork
            GallerySection.progress
            GallerySection.controls
            GallerySection.surfaces
            GallerySection.navigation(model: StudioSampleData.makeViewModel())
        }
    }
}

/// The gallery's sections. Text here is fixed English (`verbatim`): it's a DEBUG-only sheet.
@MainActor
enum GallerySection {

    // MARK: Tokens

    static var tokens: some View {
        GalleryPage(title: "Tokens", subtitle: "Colour, spacing, radius and elevation") {
            GalleryGroup("Surfaces & ink") {
                swatches([
                    ("canvas", Studio.Palette.canvas), ("rail", Studio.Palette.rail), ("card", Studio.Palette.card),
                    ("well", Studio.Palette.well), ("cardRaised", Studio.Palette.cardRaised), ("sheet", Studio.Palette.sheet),
                    ("cardEdge", Studio.Palette.cardEdge), ("field", Studio.Palette.field), ("segment", Studio.Palette.segment),
                    ("track", Studio.Palette.track), ("ink", Studio.Palette.ink), ("ink2", Studio.Palette.ink2),
                    ("ink3", Studio.Palette.ink3), ("hairline", Studio.Palette.hairline), ("hairlineStrong", Studio.Palette.hairlineStrong),
                ])
            }
            GalleryGroup("Accent & semantic") {
                swatches([
                    ("accent", Studio.Palette.accent), ("accentStrong", Studio.Palette.accentStrong),
                    ("onAccent", Studio.Palette.onAccent), ("accentSoft", Studio.Palette.accentSoft),
                    ("accentLine", Studio.Palette.accentLine), ("focusRing", Studio.Palette.focusRing),
                    ("good", Studio.Palette.good), ("goodSoft", Studio.Palette.goodSoft), ("warn", Studio.Palette.warn),
                    ("warnSoft", Studio.Palette.warnSoft), ("bad", Studio.Palette.bad), ("badSoft", Studio.Palette.badSoft),
                    ("info", Studio.Palette.info), ("infoSoft", Studio.Palette.infoSoft), ("upload", Studio.Palette.upload),
                    ("uploadSoft", Studio.Palette.uploadSoft), ("scrim", Studio.Palette.scrim), ("glass", Studio.Palette.glass),
                ])
            }
            GalleryGroup("File-type tints (fill · deep · ink · soft)") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Studio.Space.m), count: 5), alignment: .leading, spacing: Studio.Space.m) {
                    ForEach(StudioArtKind.allCases, id: \.self) { kind in
                        let tint = kind.tint
                        VStack(alignment: .leading, spacing: Studio.Space.xs) {
                            HStack(spacing: Studio.Space.xxs) {
                                ForEach(Array([tint.fill, tint.fillDeep, tint.ink, tint.soft].enumerated()), id: \.offset) { _, color in
                                    RoundedRectangle(cornerRadius: Studio.Radius.badge).fill(color).frame(height: 28)
                                }
                            }
                            Text(verbatim: kind.rawValue).studioFont(.caption).foregroundStyle(Studio.Palette.ink2)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: Studio.Space.xxl) {
                GalleryGroup("Spacing") {
                    VStack(alignment: .leading, spacing: Studio.Space.xs) {
                        ForEach([("hair", Studio.Space.hair), ("xxs", Studio.Space.xxs), ("xs", Studio.Space.xs),
                                 ("s", Studio.Space.s), ("sm", Studio.Space.sm), ("m", Studio.Space.m), ("ml", Studio.Space.ml),
                                 ("l", Studio.Space.l), ("xl", Studio.Space.xl), ("gutter", Studio.Space.gutter),
                                 ("xxl", Studio.Space.xxl), ("xxxl", Studio.Space.xxxl)], id: \.0) { name, value in
                            HStack(spacing: Studio.Space.s) {
                                Text(verbatim: "\(name) \(Int(value))").studioFont(.monoSmall).foregroundStyle(Studio.Palette.ink2)
                                    .frame(width: 80, alignment: .leading)
                                RoundedRectangle(cornerRadius: 2).fill(Studio.Palette.accent).frame(width: value * 4, height: 8)
                            }
                        }
                    }
                }
                GalleryGroup("Radii") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: Studio.Space.sm), count: 4), spacing: Studio.Space.sm) {
                        ForEach([("badge", Studio.Radius.badge), ("small", Studio.Radius.small), ("control", Studio.Radius.control),
                                 ("well", Studio.Radius.well), ("tile", Studio.Radius.tile), ("card", Studio.Radius.card),
                                 ("boardCard", Studio.Radius.boardCard), ("sheet", Studio.Radius.sheet)], id: \.0) { name, value in
                            VStack(spacing: Studio.Space.xxs) {
                                RoundedRectangle(cornerRadius: value, style: .continuous)
                                    .fill(Studio.Palette.card)
                                    .overlay(RoundedRectangle(cornerRadius: value, style: .continuous).strokeBorder(Studio.Palette.hairlineStrong))
                                    .frame(width: 60, height: 44)
                                Text(verbatim: "\(name) \(Int(value))").studioFont(.tiny).foregroundStyle(Studio.Palette.ink3)
                            }
                        }
                    }
                }
                GalleryGroup("Elevation 0–3") {
                    HStack(spacing: 22) {
                        ForEach(Studio.Elevation.allCases, id: \.self) { level in
                            Text(verbatim: "\(level.rawValue)")
                                .studioFont(.title3)
                                .foregroundStyle(Studio.Palette.ink2)
                                .frame(width: 72, height: 72)
                                .studioSurface(.card, radius: Studio.Radius.card, elevation: level)
                        }
                    }
                    .padding(.vertical, Studio.Space.m)
                }
            }
        }
    }

    private static func swatches(_ items: [(String, Color)]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Studio.Space.sm), count: 9), alignment: .leading, spacing: Studio.Space.sm) {
            ForEach(items, id: \.0) { name, color in
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
                        .fill(color)
                        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous).strokeBorder(Studio.Palette.cardEdge))
                        .frame(height: 44)
                    Text(verbatim: name).studioFont(.tiny).foregroundStyle(Studio.Palette.ink2)
                }
            }
        }
    }

    // MARK: Type

    static var type: some View {
        GalleryPage(title: "Type", subtitle: "Bricolage Grotesque · Figtree · Spline Sans Mono") {
            GalleryGroup("Scale") {
                VStack(alignment: .leading, spacing: Studio.Space.sm) {
                    ForEach(Studio.TextStyle.catalog, id: \.name) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: Studio.Space.l) {
                            Text(verbatim: "\(entry.name) · \(entry.style.size.formatted()) / \(Int(entry.style.weight))")
                                .studioFont(.monoSmall)
                                .foregroundStyle(Studio.Palette.ink3)
                                .frame(width: 190, alignment: .leading)
                            Text(verbatim: sample(for: entry.style))
                                .studioFont(entry.style)
                                .foregroundStyle(Studio.Palette.ink)
                                .lineLimit(1)
                        }
                    }
                }
            }
            GalleryGroup("Every weight") {
                VStack(alignment: .leading, spacing: Studio.Space.s) {
                    ForEach(StudioFontFamily.allCases, id: \.self) { family in
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            Text(verbatim: family.familyName + (StudioFonts.isAvailable(family) ? "" : " (fallback)"))
                                .studioFont(.monoSmall)
                                .foregroundStyle(Studio.Palette.ink3)
                                .frame(width: 150, alignment: .leading)
                            ForEach([300, 400, 500, 600, 650, 700, 750, 800], id: \.self) { weight in
                                Text(verbatim: "62% \(weight)")
                                    .studioFont(family, size: 17, weight: CGFloat(weight))
                                    .foregroundStyle(Studio.Palette.ink)
                            }
                        }
                    }
                }
            }
            GalleryGroup("Tabular numbers") {
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    ForEach(["↓ 12.0 MB/s · 2.9 of 4.7 GB", "↓ 111.1 MB/s · 1.1 of 1.1 GB", "↑ 640 KB/s · 3m left"], id: \.self) { line in
                        Text(verbatim: line).studioFont(.mono)
                    }
                    Text(verbatim: "1111 — 8888 (display, tabular)").studioFont(.stat)
                }
                .foregroundStyle(Studio.Palette.ink)
            }
        }
    }

    private static func sample(for style: Studio.TextStyle) -> String {
        switch style.family {
        case .display: return style.size >= 24 ? "62% Studio" : "Downloading · Up next"
        case .ui: return "Paste a link, magnet or stream — or search"
        case .mono: return "↓ 12 MB/s · 2.9 of 4.7 GB · 3m"
        }
    }

    // MARK: Artwork

    static var artwork: some View {
        GalleryPage(title: "Artwork", subtitle: "One tint and pattern per file type, in XS · S · M · L") {
            VStack(alignment: .leading, spacing: Studio.Space.ml) {
                ForEach(StudioArtKind.allCases, id: \.self) { kind in
                    HStack(spacing: Studio.Space.ml) {
                        Text(verbatim: kind.rawValue)
                            .studioFont(.monoSmall)
                            .foregroundStyle(Studio.Palette.ink3)
                            .frame(width: 70, alignment: .leading)
                        ForEach(StudioArtSize.allCases, id: \.self) { size in
                            StudioFileArtwork(kind: kind, size: size)
                        }
                        StudioFileArtwork(kind: kind, size: .m, isFaded: true)
                        StudioArtworkBand(kind: kind, height: 66) {
                            StudioBadge("HTTP", style: .glass)
                        }
                        .frame(width: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                HStack(spacing: Studio.Space.ml) {
                    Text(verbatim: "variants")
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink3)
                        .frame(width: 70, alignment: .leading)
                    StudioFileArtwork(kind: .magnet, size: .m, isFetchingMetadata: true)
                    StudioFileArtwork(kind: .magnet, size: .l, isFetchingMetadata: true)
                    StudioFileArtwork(kind: .other, size: .m, isGhost: true)
                    Text(verbatim: "magnet fetching metadata · ghost placeholder · faded (paused) above")
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                }
            }
        }
    }

    // MARK: Progress & status

    static var progress: some View {
        GalleryPage(title: "Progress & status", subtitle: "Arcs, bars, status chips, badges") {
            GalleryGroup("Progress arcs") {
                HStack(alignment: .center, spacing: 22) {
                    StudioProgressArc(fraction: 0.62)
                    StudioProgressArc(fraction: 0.34, tone: .paused)
                    StudioProgressArc(fraction: 0.6, tone: .upload)
                    StudioProgressArc(fraction: 1, tone: .good)
                    StudioProgressArc(fraction: 0.3, tone: .bad)
                    StudioProgressArc(fraction: 0.8, tone: .warn)
                    StudioProgressArc(fraction: nil)
                    StudioProgressArc(fraction: 0.62, diameter: 86) {
                        Image(systemName: "arrow.down")
                            .font(StudioFonts.font(.ui, size: 20, weight: 700))
                            .foregroundStyle(Studio.Palette.accent)
                    }
                    StudioProgressArc(fraction: 0.62, diameter: 132)
                }
            }
            GalleryGroup("Linear progress") {
                VStack(alignment: .leading, spacing: Studio.Space.sm) {
                    ForEach(Array(StudioProgressTone.allCases.enumerated()), id: \.offset) { index, tone in
                        StudioLinearProgress(fraction: 0.2 + Double(index) * 0.13, tone: tone)
                    }
                    StudioLinearProgress(fraction: nil, height: StudioLinearProgress.thinHeight)
                    StudioLinearProgress(fraction: 0.34, tone: .paused, height: StudioLinearProgress.thinHeight)
                }
                .frame(width: 420)
            }
            GalleryGroup("Status chips (every download state)") {
                HStack(spacing: Studio.Space.s) {
                    ForEach(StudioDownloadState.allCases, id: \.self) { state in
                        StudioStatusChip(state: state)
                    }
                }
                HStack(spacing: Studio.Space.s) {
                    StudioStatusChip(state: .seeding, detail: "Seeding 1.20×")
                    StudioStatusChip(state: .queued, detail: "Queued · #2")
                    StudioPill("SHA-256 after finish", showsDot: false)
                    StudioPill("Matches", tone: .accent)
                }
            }
            GalleryGroup("Kind badges · tags · key caps") {
                HStack(spacing: Studio.Space.sm) {
                    ForEach(DownloadKind.allCases, id: \.self) { kind in StudioKindBadge(kind: kind) }
                    StudioBadge("1.20×", style: .accent)
                    StudioArtworkBand(kind: .video) {
                        StudioKindBadge(kind: .torrent, style: .glass)
                    }
                    .frame(width: 160)
                    .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
                    StudioTagLabel(name: "linux", color: Studio.Palette.upload)
                    StudioTagLabel(name: "work")
                    StudioKeyCaps("⌘K")
                    StudioKeyCaps(keys: ["⇧", "⌘", "T"])
                    StudioKeyCaps("⌘↩")
                }
            }
        }
    }

    // MARK: Controls

    static var controls: some View {
        GalleryPage(title: "Controls", subtitle: "Buttons, chips, segments, fields") {
            GalleryGroup("Buttons") {
                VStack(alignment: .leading, spacing: Studio.Space.sm) {
                    ForEach(Array([StudioButtonStyle.Size.small, .regular, .large].enumerated()), id: \.offset) { _, size in
                        HStack(spacing: Studio.Space.s) {
                            Button("Pause", systemImage: "pause") {}.buttonStyle(.studio(.primary, size: size))
                            Button("Folder", systemImage: "folder") {}.buttonStyle(.studio(.secondary, size: size))
                            Button("Retry in 0:12", systemImage: "arrow.clockwise") {}.buttonStyle(.studio(.soft, size: size))
                            Button("Options…") {}.buttonStyle(.studio(.ghost, size: size))
                            Button("Remove", systemImage: "trash") {}.buttonStyle(.studio(.destructive, size: size))
                            Button("Delete files") {}.buttonStyle(.studio(.destructivePrimary, size: size))
                            Button("Disabled") {}.buttonStyle(.studio(.primary, size: size)).disabled(true)
                        }
                    }
                    HStack(spacing: Studio.Space.s) {
                        StudioIconButton("xmark", label: "Close") {}
                        StudioIconButton("play.fill", label: "Resume", size: .small, bordered: true) {}
                        StudioIconButton("folder", label: "Show in Finder", bordered: true) {}
                        StudioIconButton("sidebar.left", label: "Toggle Sidebar", isOn: true) {}
                        StudioIconButton("ellipsis", label: "More", size: .small) {}
                        Button("Pill", systemImage: "line.3.horizontal.decrease") {}.buttonStyle(StudioPillButtonStyle())
                        Button("Pill on") {}.buttonStyle(StudioPillButtonStyle(isOn: true))
                    }
                    HStack(spacing: Studio.Space.s) {
                        Button("Full width primary") {}.buttonStyle(.studio(.primary, fullWidth: true))
                        Button("Full width") {}.buttonStyle(.studio(fullWidth: true))
                    }
                    .frame(width: 420)
                }
            }
            GalleryGroup("Chips & filter chips") {
                HStack(spacing: Studio.Space.xs) {
                    StudioFilterChip("All", count: 11, isOn: true) {}
                    StudioFilterChip("Active", count: 4, isOn: false) {}
                    StudioFilterChip("Queued", count: 2, isOn: false) {}
                    StudioFilterChip("Failed", count: 1, isOn: false) {}
                    StudioChip("Medium", symbol: "gauge.with.dots.needle.33percent", size: .small)
                    StudioChip("Limit off", symbol: "tortoise", size: .small)
                    StudioChip("Video", swatch: StudioArtKind.video.tint.fill)
                    StudioFilterChip("Type", symbol: "chevron.down", isOn: false, size: .small) {}
                }
            }
            GalleryGroup("Segmented control & tab bar") {
                HStack(alignment: .top, spacing: 18) {
                    StudioSegmentedControl(selection: .constant("board"), segments: [
                        StudioSegment("board", title: "Board", symbol: "rectangle.3.group"),
                        StudioSegment("list", title: "List", symbol: "list.bullet"),
                    ])
                    StudioSegmentedControl(selection: .constant("m"), segments: [
                        StudioSegment("l", title: "Low"), StudioSegment("m", title: "Medium"), StudioSegment("h", title: "High"),
                    ], size: .small)
                    StudioTabBar(selection: .constant("overview"), tabs: [
                        StudioSegment("overview", title: "Overview"),
                        StudioSegment("files", title: "Files"),
                        StudioSegment("network", title: "Network"),
                    ])
                    .frame(width: 340)
                }
            }
            GalleryGroup("Omnibox & fields") {
                VStack(alignment: .leading, spacing: Studio.Space.ml) {
                    StudioOmnibox(text: .constant(""), placeholder: "Paste a link, magnet or stream — or search") {
                        StudioOmniboxSuggestion {
                            StudioFileArtwork(kind: .disc, size: .s)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: "Copied link detected").studioFont(.eyebrow).foregroundStyle(Studio.Palette.accent)
                                Text(verbatim: "releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso")
                                    .studioFont(.body).foregroundStyle(Studio.Palette.ink).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            StudioKindBadge(kind: .http)
                            Text(verbatim: "2.6 GB").studioFont(.mono).foregroundStyle(Studio.Palette.ink2)
                            Button("Options…") {}.buttonStyle(.studio(.ghost, size: .small))
                            Button("Add", systemImage: "arrow.right") {}.buttonStyle(.studio(.primary, size: .small))
                            StudioIconButton("xmark", label: "Dismiss", size: .small) {}
                        }
                    }
                    .frame(width: 786)
                    HStack(spacing: Studio.Space.m) {
                        StudioSearchField(text: .constant(""), placeholder: "Search history").frame(width: 240)
                        StudioSearchField(text: .constant("ubuntu"), size: .small).frame(width: 200)
                        TextField("Folder name", text: .constant("Disc images")).textFieldStyle(.studio).frame(width: 220)
                        TextField("Small field", text: .constant("")).textFieldStyle(.studio(size: .small)).frame(width: 160)
                    }
                }
            }
        }
    }

    // MARK: Surfaces

    static var surfaces: some View {
        GalleryPage(title: "Surfaces", subtitle: "Cards, forms, sheets, popovers, feedback, charts") {
            HStack(alignment: .top, spacing: Studio.Space.ml) {
                VStack(alignment: .leading, spacing: Studio.Space.l) {
                    StudioFormCard(title: "Downloads", symbol: "arrow.down.circle", footer: "Applies to new downloads.") {
                        StudioToggleRow("Start downloads automatically", subtitle: "New links start as soon as they are added", isOn: .constant(true))
                        StudioToggleRow("Ask where to save each file", isOn: .constant(false))
                        StudioToggleRow("Only on Wi-Fi", isIndented: true, isOn: .constant(false))
                        StudioFormRow("Download folder", subtitle: "~/Downloads") {
                            Button("Choose…") {}.buttonStyle(.studio(size: .small))
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: Studio.Space.sm) {
                            StudioSectionHeader("Queue", detail: "last 60 s")
                            HStack(alignment: .firstTextBaseline, spacing: Studio.Space.xs) {
                                Text(verbatim: "4.1 GB").studioFont(.title2.size(28).weight(700))
                                Text(verbatim: "left · done ≈ 21:16").studioFont(.small).foregroundStyle(Studio.Palette.ink2)
                            }
                            StudioSparkline(values: sparkValues).frame(height: 44)
                            Toggle("Include seeding", isOn: .constant(true)).toggleStyle(.studioCheckbox)
                        }
                    }
                    HStack(spacing: Studio.Space.sm) {
                        StudioStatTile(value: "1.82", unit: "TB", caption: "Downloaded")
                        StudioStatTile(value: "412", caption: "Files")
                    }
                    StudioWell {
                        Text(verbatim: "A well for grouped facts.").studioFont(.small).foregroundStyle(Studio.Palette.ink2)
                    }
                }
                .frame(width: 380)
                VStack(alignment: .leading, spacing: Studio.Space.l) {
                    StudioSheet(title: "Remove 3 downloads?", subtitle: "4.1 GB on disk", symbol: "trash", onClose: {}, width: 380) {
                        StudioNote(tone: .warn, symbol: "exclamationmark.triangle", message: "Files that are still downloading will be discarded.")
                        Toggle("Also delete the files", isOn: .constant(true)).toggleStyle(.studioCheckbox)
                    } footer: {
                        StudioSheetFooter(onCancel: {}, primaryTitle: "Remove", primaryRole: .destructive, showsShortcutHint: true) {}
                    }
                    .studioSurface(.sheet, radius: Studio.Radius.sheet, elevation: .floating)
                    StudioPopover(title: "Speed limit", subtitle: "Applies to every download") {
                        StudioMenuRow(symbol: "infinity", title: "Unlimited", isChecked: true) {}
                        StudioMenuRow(symbol: "tortoise", title: "1 MB/s", shortcut: "⌥1") {}
                        StudioMenuRow(symbol: "slider.horizontal.3", title: "Custom…") {}
                        StudioDivider()
                        StudioMenuRow(symbol: "trash", title: "Clear history", isDestructive: true) {}
                    }
                    .studioSurface(.raised, radius: Studio.Radius.tile, elevation: .floating)
                    StudioCard {
                        VStack(alignment: .leading, spacing: Studio.Space.s) {
                            StudioSectionHeader("Recent throughput", detail: "peak 14.2 MB/s")
                            StudioAreaChart(values: sparkValues, secondary: sparkValues.map { $0 * 0.18 },
                                            gridLines: 2, showsEndDot: true)
                                .frame(height: 60)
                        }
                    }
                }
                .frame(width: 380)
                VStack(alignment: .leading, spacing: Studio.Space.l) {
                    StudioToastCard(tone: .good, symbol: "checkmark", title: "BigBuckBunny-1080p.mp4 finished",
                                    message: "340 MB · Video", actionTitle: "Open", onAction: {}, onDismiss: {})
                        .frame(width: 380)
                    StudioToastCard(tone: .accent, symbol: "trash", title: "Removed 2 downloads",
                                    actionTitle: "Undo", onAction: {}, onDismiss: {})
                    StudioToastCard(tone: .bad, symbol: "exclamationmark.triangle", title: "Fedora-Workstation-40.iso failed",
                                    message: "FTP server closed the connection", onDismiss: {})
                    StudioNote(tone: .accent, symbol: "info.circle", message: "Accent note: a tip next to a setting.")
                    StudioNote(tone: .bad, symbol: "exclamationmark.octagon", message: "Bad note: what went wrong, in plain words.")
                    StudioNote(symbol: "lightbulb", message: "Neutral note.")
                    StudioCard {
                        StudioEmptyState(symbol: "tray", title: "Nothing matches", message: "The Failed filter is hiding 10 downloads.") {
                            Button("Clear filter") {}.buttonStyle(.studio(.primary))
                        }
                    }
                }
                .frame(width: 380)
            }
        }
    }

    private static let sparkValues: [Double] = [30, 28, 31, 22, 24, 18, 20, 14, 17, 12, 15, 10, 13, 9].map { 44 - $0 }

    // MARK: Navigation & composition

    static func navigation(model: AppViewModel) -> some View {
        GalleryPage(title: "Navigation & composition", subtitle: "Rail, lanes, wordmark — and components combined on sample data") {
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: Studio.Space.xxs) {
                    StudioRailItem(symbol: "rectangle.3.group", title: "Downloads", badge: 4, isSelected: true, shortcut: "⌘1") {}
                    StudioRailItem(symbol: "clock.arrow.circlepath", title: "History") {}
                    StudioRailItem(symbol: "server.rack", title: "Servers") {}
                    StudioRailItem(symbol: "dot.radiowaves.up.forward", title: "Feeds", badge: 6) {}
                    StudioRailItem(symbol: "exclamationmark.triangle", title: "Needs you", badge: 1, badgeTone: .bad) {}
                    StudioRailSeparator()
                    StudioRailItem(symbol: "basket", title: "Drop Basket") {}
                    StudioRailItem(symbol: "slider.horizontal.3", title: "Settings") {}
                }
                .padding(.vertical, Studio.Space.sm)
                .frame(width: 68)
                .background(Studio.Palette.rail)
                .overlay(alignment: .trailing) { Rectangle().fill(Studio.Palette.hairline).frame(width: 1) }

                VStack(spacing: Studio.Space.hair) {
                    StudioRailItem(symbol: "rectangle.3.group", title: "Downloads", count: 11, isSelected: true, isExpanded: true) {}
                    StudioRailItem(symbol: "clock.arrow.circlepath", title: "History", count: 248, isExpanded: true) {}
                    StudioRailItem(symbol: "server.rack", title: "Servers", count: 3, isExpanded: true) {}
                    StudioRailSeparator(isExpanded: true)
                    StudioRailItem(symbol: "slider.horizontal.3", title: "Settings", isExpanded: true) {}
                }
                .padding(Studio.Space.sm)
                .frame(width: 212)
                .background(Studio.Palette.rail)

                GallerySampleLane(model: model)
                    .frame(width: 262)

                VStack(alignment: .leading, spacing: Studio.Space.sm) {
                    StudioWordmark()
                    StudioLaneHeader(title: "Up next", count: 2, detail: "starts in order")
                    GalleryCompactCard(task: StudioSampleData.task(.fieldRecordings), rank: 2)
                    GalleryCompactCard(task: StudioSampleData.task(.figma), rank: 3)
                    StudioLaneHeader(title: "Needs you", count: 2)
                    GalleryCompactCard(task: StudioSampleData.task(.fedora))
                    GalleryCompactCard(task: StudioSampleData.task(.imagenet))
                    GalleryCompactCard(task: StudioSampleData.task(.magnet))
                    GalleryCompactCard(task: StudioSampleData.task(.debian))
                }
                .frame(width: 260)
            }
        }
    }
}

/// The Downloading lane, built only from design-system parts and the sample model, to show the
/// pieces fit. Not the real board: that belongs to the Downloads area.
private struct GallerySampleLane: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        let active = model.tasks.filter { $0.status == .downloading }
        VStack(alignment: .leading, spacing: Studio.Space.cardGap) {
            StudioLaneHeader(title: "Downloading", count: active.count, detail: "↓ 43 MB/s", detailIsMono: true)
            ForEach(active) { task in
                VStack(alignment: .leading, spacing: 0) {
                    StudioArtworkBand(kind: StudioArtKind(task: task)) {
                        StudioKindBadge(kind: task.kind, style: .glass)
                    }
                    VStack(alignment: .leading, spacing: Studio.Space.hair) {
                        Text(task.name).studioFont(.cardTitle).foregroundStyle(Studio.Palette.ink).lineLimit(2)
                            .padding(.trailing, 52)
                        Text(verbatim: "\(task.sourceHost ?? "—") · \(task.totalBytes?.byteString ?? "")")
                            .studioFont(.small).foregroundStyle(Studio.Palette.ink3)
                            .padding(.trailing, 52)
                        HStack {
                            Text(verbatim: "↓ " + task.downloadSpeed.speedString).foregroundStyle(Studio.Palette.accent)
                            Spacer()
                            Text(task.statusCompactText())
                        }
                        .studioFont(.mono)
                        .foregroundStyle(Studio.Palette.ink2)
                        .padding(.top, Studio.Space.s)
                    }
                    .padding(.top, Studio.Space.sm)
                    .padding(.horizontal, Studio.Space.ml)
                    .padding(.bottom, Studio.Space.ml)
                    .overlay(alignment: .topTrailing) {
                        StudioProgressArc(fraction: task.fractionCompleted, tone: StudioProgressTone(task: task))
                            .padding(3)
                            .background(Circle().fill(Studio.Palette.card).studioElevation(.raised))
                            .offset(x: -14, y: -24)
                    }
                }
                .studioSurface(.card, radius: Studio.Radius.boardCard, elevation: .card,
                               isSelected: task.id == model.primarySelection)
            }
        }
    }
}

private struct GalleryCompactCard: View {
    let task: DownloadTask
    var rank: Int?

    var body: some View {
        let state = StudioDownloadState(task: task)
        HStack(spacing: 11) {
            if let rank {
                Text(verbatim: "#\(rank)").studioFont(.monoSmall).foregroundStyle(Studio.Palette.ink3)
            }
            StudioFileArtwork(kind: StudioArtKind(task: task), size: .s, isFaded: state == .paused,
                              isFetchingMetadata: state == .requestingMetadata)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.compactDisplayName).studioFont(.bodyStrong).foregroundStyle(Studio.Palette.ink).lineLimit(1)
                if state == .failed {
                    Text(task.statusDetailText).studioFont(.caption).foregroundStyle(Studio.Palette.bad).lineLimit(1)
                } else {
                    HStack(spacing: Studio.Space.xs) {
                        StudioStatusChip(state: state)
                        Text(task.compactSizeLine).studioFont(.caption).foregroundStyle(Studio.Palette.ink3).lineLimit(1)
                    }
                }
                if state == .requestingMetadata {
                    StudioLinearProgress(fraction: nil, height: StudioLinearProgress.thinHeight)
                } else if state == .paused || state == .seeding {
                    StudioLinearProgress(fraction: state == .seeding ? task.seedRatioProgress ?? 0.6 : task.fractionCompleted,
                                         tone: StudioProgressTone(task: task), height: StudioLinearProgress.thinHeight)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, 11)
        .studioSurface(.card, radius: Studio.Radius.compactCard)
        .accessibilityElement(children: .combine)
    }
}

/// A gallery page: display title and a stack of groups on the canvas.
private struct GalleryPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                Text(verbatim: "Studio").studioFont(.eyebrow).foregroundStyle(Studio.Palette.accent)
                Text(verbatim: title).studioFont(.title1).foregroundStyle(Studio.Palette.ink)
                Text(verbatim: subtitle).studioFont(.body).foregroundStyle(Studio.Palette.ink2)
            }
            content()
        }
        .padding(Studio.Space.xxxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.Palette.canvas)
    }
}

private struct GalleryGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            Text(verbatim: title).studioFont(.eyebrow).foregroundStyle(Studio.Palette.ink3)
            content()
        }
    }
}
#endif
