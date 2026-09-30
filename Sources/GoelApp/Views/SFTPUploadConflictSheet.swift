import SwiftUI
import GoelCore

struct SFTPUploadConflictSheet: View {
    let request: SFTPUploadConflictRequest
    let onResolve: ([UUID: SFTPUploadConflictRequest.Policy]) -> Void
    let onCancel: () -> Void

    @State private var decisions: [UUID: SFTPUploadConflictRequest.Policy] = [:]

    private typealias Policy = SFTPUploadConflictRequest.Policy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            applyToAll
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 260, maxHeight: 560)
        .onAppear {
            for item in request.colliding where decisions[item.id] == nil {
                decisions[item.id] = .rename
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 22).foregroundStyle(Theme.orange)
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 3) {
                Text(request.colliding.count == 1
                     ? L10n.t("An item already exists")
                     : L10n.t("%d items already exist", request.colliding.count))
                    .scaledFont(size: Theme.TextSize.title, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.t("These already exist in %@. Choose what to do with each.", displayDir))
                    .scaledFont(size: Theme.TextSize.body).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var applyToAll: some View {
        HStack(spacing: 8) {
            Text(L10n.t("Apply to all")).scaledFont(size: Theme.TextSize.meta, weight: .semibold).foregroundStyle(.secondary)
            Spacer()
            ForEach(Policy.allCases) { policy in
                Button(L10n.t(policy.rawValue)) { setAll(policy) }
                    .buttonStyle(.plain)
                    .scaledFont(size: Theme.TextSize.meta, weight: .medium)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(L10n.t("Apply %@ to all items", L10n.t(policy.rawValue)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(request.colliding) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(item.isDirectory ? Theme.accent : .secondary)
                            .frame(width: 18)
                            .a11yDecorative()
                        Text(item.name).scaledFont(size: Theme.TextSize.title).lineLimit(1).truncationMode(.middle)
                            .accessibilityLabel(L10n.t("%1$@, %2$@",
                                                       item.isDirectory ? L10n.t("Folder") : L10n.t("File"),
                                                       item.name))
                        Spacer(minLength: 12)
                        Picker("", selection: binding(for: item.id)) {
                            ForEach(Policy.allCases) { Text(L10n.t($0.rawValue)).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                        .accessibilityLabel(L10n.t("What to do with %@", item.name))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(summary).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("Cancel"), role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("Upload")) { onResolve(decisions) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var displayDir: String { request.remoteDir == "." ? L10n.t("Home") : request.remoteDir }

    private var summary: String {
        var counts: [Policy: Int] = [:]
        for item in request.colliding { counts[decisions[item.id] ?? .rename, default: 0] += 1 }
        return Policy.allCases
            .compactMap { p in (counts[p] ?? 0) > 0 ? L10n.t("%1$@ %2$@", String(counts[p]!), L10n.midSentence(L10n.t(p.rawValue))) : nil }
            .joined(separator: " · ")
    }

    private func binding(for id: UUID) -> Binding<Policy> {
        Binding(get: { decisions[id] ?? .rename }, set: { decisions[id] = $0 })
    }

    private func setAll(_ policy: Policy) {
        for item in request.colliding { decisions[item.id] = policy }
    }
}
