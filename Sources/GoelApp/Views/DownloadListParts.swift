import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The seeding row's 40 pt bar toward its ratio target, beside "Seeding 1.84×".
struct SeedTargetBar: View {
    let progress: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(Theme.teal)
                .frame(width: 40 * CGFloat(min(max(progress, 0), 1)))
        }
        .frame(width: 40, height: 3)
        // The row's accessibility value already speaks the ratio and its target.
        .a11yDecorative()
    }
}

/// A Group by header: pinned while its rows scroll under it.
struct ListSectionHeader: View {
    let section: ListSection

    var body: some View {
        HStack(spacing: 6) {
            Text(section.title.uppercased())
                .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(summary)
                .scaledFont(size: Theme.TextSize.caption, weight: .semibold, monospacedDigit: true)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(section.title, spokenSummary))
        .accessibilityAddTraits(.isHeader)
    }

    /// "12 · 4.2 GB"; the size is left off while nothing in the group has a known size.
    private var summary: String {
        let total = section.totalBytes
        return total > 0 ? L10n.t("%1$d · %2$@", section.tasks.count, total.byteString) : "\(section.tasks.count)"
    }

    private var spokenSummary: String {
        let count = section.tasks.count == 1
            ? L10n.t("%d download", section.tasks.count)
            : L10n.t("%d downloads", section.tasks.count)
        let total = section.totalBytes
        return total > 0 ? A11y.sentence(count, A11y.bytes(total)) : count
    }
}

/// Makes a row a drop target for a queue drag: the top half inserts above it, the bottom half
/// below, shown by a 2 pt accent line on that edge. Applied outside the row's `.equatable()`, so
/// the drag feedback never invalidates the row itself.
struct QueueDropTarget: ViewModifier {
    let taskID: DownloadTask.ID
    let enabled: Bool
    let vm: AppViewModel

    @State private var height: CGFloat = 0
    @State private var edge: VerticalEdge?

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height = $0 })
                .overlay(alignment: edge == .bottom ? .bottom : .top) {
                    if edge != nil {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .allowsHitTesting(false)
                            .a11yDecorative()
                    }
                }
                .onDrop(of: [.plainText], delegate: QueueDropDelegate(
                    taskID: taskID, height: height, edge: $edge, vm: vm))
        } else {
            content
        }
    }
}

private struct QueueDropDelegate: DropDelegate {
    let taskID: DownloadTask.ID
    let height: CGFloat
    @Binding var edge: VerticalEdge?
    let vm: AppViewModel

    /// Only a drag this list started: any other text dropped here (a URL from Safari) is not a reorder.
    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { !vm.queueDragIDs.isEmpty }
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let above = edge != .bottom
        edge = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let anchor = taskID
        let vm = self.vm
        // The payload names the rows. It must match what the grip recorded, so a stale record
        // left by a cancelled drag can never move rows on an unrelated drop.
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let payload = (object as? NSString).map(String.init) ?? ""
            Task { @MainActor in
                let ids = payload.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
                guard !ids.isEmpty, ids == vm.queueDragIDs else { vm.queueDragIDs = []; return }
                vm.dropQueueDrag(onto: anchor, above: above)
            }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let next: VerticalEdge = height > 0 && info.location.y > height / 2 ? .bottom : .top
        if edge != next { edge = next }
    }
}

/// Observes ``MediaJobCenter`` directly: a nested observable's changes don't propagate through the outer one.
struct MediaMenuItems: View {

    let task: DownloadTask
    let vm: AppViewModel
    @ObservedObject var center: MediaJobCenter

    private var input: URL { URL(fileURLWithPath: task.savePath) }

    var body: some View {
        if let reason = vm.ffmpegUnavailableReason {
            Button(L10n.t("Convert To…")) { vm.toastNow(reason) }
            Button(L10n.t("Extract Audio…")) { vm.toastNow(reason) }
        } else {
            jobItems
        }
    }

    @ViewBuilder
    private var jobItems: some View {
        let live = center.liveJobs(input: input)
        ForEach(live) { job in
            Button(L10n.t("Cancel %@", L10n.midSentence(job.kind.activeTitle))) { center.cancel(job.id) }
        }
        if !live.isEmpty { Divider() }
        Menu(L10n.t("Convert To")) {
            ForEach(MediaContainer.convertTargets, id: \.self) { ext in
                Button(label(for: ext)) { vm.convertFile(task: task, toExtension: ext) }
                    .disabled(center.liveJob(input: input, outputExtension: ext) != nil)
            }
        }
        Menu(L10n.t("Extract Audio")) {
            ForEach(AudioExtractionFormat.allCases, id: \.self) { format in
                Button(format.displayName) { vm.extractAudio(task: task, format: format) }
                    .disabled(center.liveJob(input: input, outputExtension: format.rawValue) != nil)
            }
        }
    }

    private func label(for ext: String) -> String {
        let source = input.pathExtension
        guard !source.isEmpty,
              MediaContainer.likelyStreamCopy(from: source, to: ext) else {
            return ext.uppercased()
        }
        return L10n.t("%@ — copy, instant", ext.uppercased())
    }
}

/// How a row asks the list to Quick Look a file. It lives in the environment rather than as a
/// closure parameter: a fresh closure on every list body made every row compare as changed.
struct QuickLookAction: Equatable {
    var item: Binding<URL?>?

    func callAsFunction(_ url: URL) { item?.wrappedValue = url }

    /// Always equal: the binding points at the same `@State` for the life of the list.
    static func == (lhs: QuickLookAction, rhs: QuickLookAction) -> Bool { true }
}

private struct QuickLookActionKey: EnvironmentKey {
    static let defaultValue = QuickLookAction(item: nil)
}

extension EnvironmentValues {
    var quickLookAction: QuickLookAction {
        get { self[QuickLookActionKey.self] }
        set { self[QuickLookActionKey.self] = newValue }
    }
}
