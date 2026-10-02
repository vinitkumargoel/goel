import SwiftUI
import GoelCore

/// Some of an upload's items already exist on the server: pick Overwrite, Resume, Rename or Skip
/// for each (Rename by default), or one choice for all, then Upload.
struct SFTPUploadConflictSheet: View {
    let request: SFTPUploadConflictRequest
    let onResolve: ([UUID: SFTPUploadConflictRequest.Policy]) -> Void
    let onCancel: () -> Void

    @State private var decisions: [UUID: SFTPUploadConflictRequest.Policy] = [:]

    private typealias Policy = SFTPUploadConflictRequest.Policy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            applyToAll
                .padding(.horizontal, Studio.Space.xl)
                .padding(.bottom, Studio.Space.s)
            StudioDivider()
            list
            StudioSheetFooter(onCancel: onCancel, primaryTitle: L10n.t("Upload"), primarySymbol: "arrow.up.doc",
                              onPrimary: { onResolve(decisions) }) {
                Text(summary)
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(1)
            }
        }
        .frame(width: 560)
        .frame(minHeight: 260, maxHeight: 560)
        .background(Studio.Palette.sheet)
        .onAppear {
            for item in request.colliding where decisions[item.id] == nil {
                decisions[item.id] = .rename
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Studio.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(StudioFonts.font(.ui, size: 16, weight: 650))
                .foregroundStyle(Studio.Palette.warn)
                .frame(width: 36, height: 36)
                .background(Studio.Palette.warnSoft,
                            in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 3) {
                Text(request.colliding.count == 1
                     ? L10n.t("An item already exists")
                     : L10n.t("%d items already exist", request.colliding.count))
                    .studioFont(.title2)
                    .foregroundStyle(Studio.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.t("These already exist in %@. Choose what to do with each.",
                            L10n.t("%1$@ on %2$@", displayDir, request.connection.label)))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.top, 18)
        .padding(.bottom, Studio.Space.m)
    }

    private var applyToAll: some View {
        HStack(spacing: Studio.Space.xs) {
            Text(L10n.t("Apply to all"))
                .studioFont(.callout.weight(650))
                .foregroundStyle(Studio.Palette.ink2)
            Spacer()
            ForEach(Policy.allCases) { policy in
                Button(Self.title(policy)) { setAll(policy) }
                    .buttonStyle(StudioPillButtonStyle(isOn: allAre(policy), size: .small))
                    .accessibilityLabel(L10n.t("Apply %@ to all items", Self.title(policy)))
                    .accessibilityAddTraits(allAre(policy) ? .isSelected : [])
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(request.colliding.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { StudioDivider().padding(.leading, Studio.Space.xl + 34) }
                    row(item)
                }
            }
            .padding(.vertical, Studio.Space.xs)
        }
    }

    private func row(_ item: SFTPUploadConflictRequest.Item) -> some View {
        HStack(spacing: Studio.Space.sm) {
            StudioFileArtwork(kind: item.isDirectory ? .folder : SFTPFileIcon.artKind(forName: item.name), size: .xs)
            FileNameText(item.name, lineLimit: 1)
                .studioFont(.body.weight(550))
                .foregroundStyle(Studio.Palette.ink)
                .accessibilityLabel(L10n.t("%1$@, %2$@",
                                           item.isDirectory ? L10n.t("Folder") : L10n.t("File"), item.name))
            Spacer(minLength: Studio.Space.m)
            StudioSegmentedControl(
                selection: binding(for: item.id),
                segments: Policy.allCases.map { StudioSegment($0, title: Self.title($0)) },
                size: .small,
                accessibilityLabel: L10n.t("What to do with %@", item.name))
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.vertical, Studio.Space.s)
    }

    private var displayDir: String { request.remoteDir == "." ? L10n.t("Home") : request.remoteDir }

    private var summary: String {
        var counts: [Policy: Int] = [:]
        for item in request.colliding { counts[decisions[item.id] ?? .rename, default: 0] += 1 }
        return Policy.allCases
            .compactMap { p in
                guard let count = counts[p], count > 0 else { return nil }
                return L10n.t("%1$@ %2$@", String(count), L10n.midSentence(Self.title(p)))
            }
            .joined(separator: " · ")
    }

    private func allAre(_ policy: Policy) -> Bool {
        !request.colliding.isEmpty && request.colliding.allSatisfy { (decisions[$0.id] ?? .rename) == policy }
    }

    private func binding(for id: UUID) -> Binding<Policy> {
        Binding(get: { decisions[id] ?? .rename }, set: { decisions[id] = $0 })
    }

    private func setAll(_ policy: Policy) {
        for item in request.colliding { decisions[item.id] = policy }
    }

    static func title(_ policy: SFTPUploadConflictRequest.Policy) -> String {
        switch policy {
        case .overwrite: return L10n.t("Overwrite")
        case .resume: return L10n.t("Resume")
        case .rename: return L10n.t("Rename")
        case .skip: return L10n.t("Skip")
        }
    }
}
