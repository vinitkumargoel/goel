import SwiftUI
import AppKit
import GoelCore

/// One finished download: artwork, name, protocol · site · size, the time, a Missing badge when
/// the file has gone, and its actions in place while hovered or selected.
struct HistoryRow: View {
    let item: HistoryPresentation.Item
    let isSelected: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onLocate: () -> Void
    let onRedownload: () -> Void
    let onCopyLink: () -> Void
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        WindowsCompactCard(isSelected: isSelected, isHovered: hovered && !isSelected) {
            StudioFileArtwork(kind: StudioArtKind(item.type), size: .m, isFaded: !item.exists)
            VStack(alignment: .leading, spacing: 2) {
                FileNameText(item.entry.name, lineLimit: 1)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(item.exists ? Studio.Palette.ink : Studio.Palette.ink2)
                Text(subtitle)
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.entry.name)
            .accessibilityValue(spokenValue)
            if !item.exists {
                StudioPill(L10n.t("Missing"), tone: .warn)
            }
            if hovered || isSelected {
                actions
            } else {
                Text(DisplayFormat.compactDateTime(item.entry.completedAt, locale: DisplayFormat.appLocale))
                    .studioFont(.small)
                    .monospacedDigit()
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(1)
                    .help(DisplayFormat.relativeDateTime(item.entry.completedAt, locale: DisplayFormat.appLocale))
            }
        }
        .onHover { hovered = $0 }
        .help(item.exists ? item.entry.savePath : L10n.t("The file is no longer at %@", item.entry.savePath))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: L10n.t("Open"), onOpen)
        .accessibilityAction(named: L10n.t("Download again"), onRedownload)
        .accessibilityAction(named: L10n.t("Remove from History"), onRemove)
    }

    private var actions: some View {
        HStack(spacing: Studio.Space.xxs) {
            if item.exists {
                Button(L10n.t("Open"), action: onOpen)
                    .buttonStyle(.studio(.secondary, size: .small))
                    .accessibilityLabel(L10n.t("Open %@", item.entry.name))
                StudioIconButton("folder", label: L10n.t("Show %@ in Finder", item.entry.name), size: .small,
                                 bordered: true, action: onReveal)
                    .help(L10n.t("Show in Finder"))
            } else {
                Button(L10n.t("Locate…"), action: onLocate)
                    .buttonStyle(.studio(.secondary, size: .small))
                    .accessibilityLabel(L10n.t("Locate “%@”", item.entry.name))
            }
            StudioIconButton("arrow.down.circle", label: L10n.t("Download “%@” again", item.entry.name),
                             size: .small, bordered: true, action: onRedownload)
                .help(L10n.t("Download again"))
            StudioIconButton("link", label: L10n.t("Copy Link"), size: .small, bordered: true, action: onCopyLink)
            Menu {
                Button(L10n.t("Open"), action: onOpen).disabled(!item.exists)
                Button(L10n.t("Show in Finder"), action: onReveal).disabled(!item.exists)
                if !item.exists { Button(L10n.t("Locate…"), action: onLocate) }
                Divider()
                Button(L10n.t("Download Again"), action: onRedownload)
                Button(L10n.t("Copy Link"), action: onCopyLink)
                Divider()
                Button(L10n.t("Remove from History"), role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(StudioIconButtonStyle(size: .small, bordered: true))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.t("More"))
            .accessibilityLabel(L10n.t("More actions for %@", item.entry.name))
        }
    }

    /// "HLS · test-streams.mux.dev · 340 MB".
    private var subtitle: String {
        var parts = [item.entry.kind.badgeLabel]
        if let host = URL(string: item.entry.locator)?.host, !host.isEmpty { parts.append(host) }
        if let bytes = item.entry.totalBytes, bytes > 0 { parts.append(bytes.byteString) }
        return parts.joined(separator: " · ")
    }

    private var spokenValue: String {
        A11y.sentence(item.entry.completedAt.formatted(date: .abbreviated, time: .shortened),
                      item.entry.totalBytes.map(A11y.bytes),
                      item.exists ? nil : L10n.t("File missing"))
    }
}

/// The side card: what is in view, in bytes and files, and which kinds of file make it up.
struct HistorySummaryCard: View {
    let items: [HistoryPresentation.Item]

    var body: some View {
        let bytes = items.reduce(Int64(0)) { $0 + max(0, $1.entry.totalBytes ?? 0) }
        let missing = items.filter { !$0.exists }.count
        let parts = StatsUnits.split(bytes.byteString)
        StudioCard {
            VStack(alignment: .leading, spacing: Studio.Space.sm) {
                WindowsEyebrow(L10n.t("In view"))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(parts.value).studioFont(.display, size: 34, weight: 750, tabularNumbers: true)
                    if let unit = parts.unit {
                        Text(unit).studioFont(.title3).foregroundStyle(Studio.Palette.ink2)
                    }
                }
                .foregroundStyle(Studio.Palette.ink)
                Text(missing > 0
                     ? L10n.t("%1$@ finished · %2$@ missing", String(items.count), String(missing))
                     : L10n.t("%@ finished", String(items.count)))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                VStack(spacing: Studio.Space.xs) {
                    ForEach(breakdown, id: \.type) { entry in
                        HStack(spacing: Studio.Space.s) {
                            StudioFileArtwork(kind: StudioArtKind(entry.type), size: .xs)
                            Text(entry.type.accessibilityName)
                                .studioFont(.small)
                                .foregroundStyle(Studio.Palette.ink)
                            Spacer(minLength: Studio.Space.s)
                            Text(entry.bytes.byteString)
                                .studioFont(.monoSmall)
                                .foregroundStyle(Studio.Palette.ink2)
                        }
                    }
                }
                .padding(.top, Studio.Space.xxs)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The four kinds of file with the most bytes.
    private var breakdown: [(type: FileType, bytes: Int64)] {
        var totals: [FileType: Int64] = [:]
        for item in items {
            totals[item.type, default: 0] += max(0, item.entry.totalBytes ?? 0)
        }
        let ranked: [(type: FileType, bytes: Int64)] = totals
            .filter { $0.value > 0 }
            .map { (type: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
        return Array(ranked.prefix(4))
    }
}
