import SwiftUI
import GoelCore

/// Shown before an upload would overwrite same-named remote items. Each colliding
/// item gets an Overwrite / Rename / Skip choice (defaulting to Rename, the safe
/// option), with an "Apply to all" shortcut. Non-colliding items in the same
/// batch aren't listed — they upload regardless of what's chosen here.
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
        .frame(width: 480)
        .frame(minHeight: 260, maxHeight: 560)
        .onAppear {
            for item in request.colliding where decisions[item.id] == nil {
                decisions[item.id] = .rename
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22)).foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.colliding.count == 1
                     ? "An item already exists"
                     : "\(request.colliding.count) items already exist")
                    .font(.system(size: 14, weight: .semibold))
                Text("These already exist in \(displayDir). Choose what to do with each.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var applyToAll: some View {
        HStack(spacing: 8) {
            Text("Apply to all").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            ForEach(Policy.allCases) { policy in
                Button(policy.rawValue) { setAll(policy) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
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
                        Text(item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Picker("", selection: binding(for: item.id)) {
                            ForEach(Policy.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(summary).font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Upload") { onResolve(decisions) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    // MARK: Helpers

    private var displayDir: String { request.remoteDir == "." ? "Home" : request.remoteDir }

    /// A live count of what the current choices will do, e.g. "2 overwrite · 1 skip".
    private var summary: String {
        var counts: [Policy: Int] = [:]
        for item in request.colliding { counts[decisions[item.id] ?? .rename, default: 0] += 1 }
        return Policy.allCases
            .compactMap { p in (counts[p] ?? 0) > 0 ? "\(counts[p]!) \(p.rawValue.lowercased())" : nil }
            .joined(separator: " · ")
    }

    private func binding(for id: UUID) -> Binding<Policy> {
        Binding(get: { decisions[id] ?? .rename }, set: { decisions[id] = $0 })
    }

    private func setAll(_ policy: Policy) {
        for item in request.colliding { decisions[item.id] = policy }
    }
}
