import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// How a row or card asks the list to Quick Look a file. It lives in the environment rather than
/// as a closure parameter: a fresh closure on every list body made every row compare as changed.
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

/// Everything a row and a card do the same way: click, ⌘-click and ⇧-click selection,
/// double-click to open, the context menu, dragging a finished file out to Finder, and the
/// VoiceOver label, value, hint and actions.
struct DownloadItemBehaviour: ViewModifier {
    let task: DownloadTask
    let layout: DownloadsLayout
    let isSelected: Bool
    let queueRank: Int?
    let summary: DownloadSelectionSummary?
    let context: DownloadItemContext
    let vm: AppViewModel
    let quickLook: QuickLookAction

    func body(content: Content) -> some View {
        accessible(content
            .onTapGesture(perform: handleTap)
            // Simultaneous, so a single click selects at once instead of waiting out the double-click interval.
            .simultaneousGesture(TapGesture(count: 2).onEnded { vm.openOrReveal(task) })
            .contextMenu {
                DownloadContextMenu(task: task, summary: summary, context: context, vm: vm, quickLook: quickLook)
            }
            .onDrag {
                guard task.status.hasData else { return NSItemProvider() }
                return NSItemProvider(object: URL(fileURLWithPath: task.savePath) as NSURL)
            })
    }

    private func handleTap() {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) {
            // ⇧⌘ adds the run to what is already selected; plain ⇧ replaces it.
            vm.extendSelection(through: task.id, additive: mods.contains(.command), in: layout)
        } else if mods.contains(.command) {
            vm.toggleSelection(task.id)
        } else {
            vm.selectOnly(task.id)
        }
    }

    private func accessible<Content: View>(_ content: Content) -> some View {
        let traits: AccessibilityTraits = isSelected
            ? [.isButton, .isSelected, .updatesFrequently]
            : [.isButton, .updatesFrequently]
        return content
            // Label is identity only: folding in the ticking percent makes VoiceOver re-speak the row every second.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(task.accessibilityIdentityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(traits)
            .accessibilityHint(failureHint ?? L10n.t("Select to show details."))
            .accessibilityAction(named: Text(L10n.t(task.accessibilityStateActionName)), primaryStateAction)
            .accessibilityAction(named: Text(L10n.t("Show in Finder"))) { vm.revealInFinder(task) }
            .accessibilityAction(named: Text(L10n.t("Copy source link"))) { vm.copyToPasteboard(task.sourceLocator) }
            .accessibilityAction(named: Text(L10n.t("Remove from list"))) { vm.remove(task.id, deleteData: false) }
            // The keyboard and VoiceOver path to reordering; dragging is pointer-only.
            .accessibilityAction(named: Text(L10n.t("Move to Top of Queue"))) {
                vm.moveInQueue(vm.queueTargets(for: task.id), to: .top)
            }
            .accessibilityAction(named: Text(L10n.t("Move to Bottom of Queue"))) {
                vm.moveInQueue(vm.queueTargets(for: task.id), to: .bottom)
            }
    }

    /// The progress value plus what a compact status leaves out: the ratio against its target
    /// while seeding, the place in line while queued.
    private var accessibilityValue: String {
        switch task.status {
        case .seeding: return A11y.sentence(task.accessibilityProgressValue, task.statusDetailText)
        case .queued: return A11y.sentence(task.accessibilityProgressValue, task.statusCompactText(queueRank: queueRank))
        default: return task.accessibilityProgressValue
        }
    }

    private var failureHint: String? {
        guard case .failed(let error) = task.status else { return nil }
        return FailureAdvice.hint(for: error)
    }

    private func primaryStateAction() {
        switch task.status {
        case .completed: task.isFileMissing ? vm.locateMissingFile(task) : vm.revealInFinder(task)
        case .failed: vm.retry(task.id)
        case .paused, .queued: vm.resume(task.id)
        default: vm.pause(task.id)
        }
    }
}

extension DownloadTask {
    /// The status tooltip: for a failure the reason plus the advice, otherwise the long form.
    var studioStatusTooltip: String {
        guard case .failed(let error) = status else { return statusDetailText }
        return A11y.sentence(error.message, FailureAdvice.hint(for: error))
    }

    /// The failure's reason, nil for anything else.
    var failureMessage: String? {
        if case .failed(let error) = status { return error.message }
        return nil
    }
}

/// Owns the hover state so the row or card it wraps stays a pure value: only the hovered item's
/// equality changes when the pointer moves.
struct HoverTracking<Content: DownloadHoverable>: View, Equatable {
    let content: Content

    @State private var hovered = false

    static func == (lhs: HoverTracking, rhs: HoverTracking) -> Bool { lhs.content == rhs.content }

    var body: some View {
        var shown = content
        shown.isHovered = hovered
        return shown
            .equatable()
            .onHover { hovered = $0 }
    }
}

/// A row or card whose hover state ``HoverTracking`` sets.
protocol DownloadHoverable: View, Equatable {
    var isHovered: Bool { get set }
}

/// The seeding row's 40 pt bar toward its ratio target, beside "Seeding 1.84×".
struct SeedTargetBar: View {
    let progress: Double
    var width: CGFloat = 40

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Studio.Palette.track)
            Capsule()
                .fill(Studio.Palette.upload)
                .frame(width: width * CGFloat(min(max(progress, 0), 1)))
        }
        .frame(width: width, height: 4)
        // The row's accessibility value already speaks the ratio and its target.
        .a11yDecorative()
    }
}

/// A status pill that may shrink: unlike `StudioPill` it truncates inside a fixed column.
struct DownloadStatusPill: View {
    let text: String
    let tone: StudioTone

    var body: some View {
        HStack(spacing: Studio.Space.xs) {
            Circle().fill(tone.foreground).frame(width: 6, height: 6).a11yDecorative()
            Text(text)
                .studioFont(Studio.TextStyle.caption.weight(650).tabular)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 9)
        .frame(minHeight: 22)
        .background(tone.background, in: Capsule())
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
                        Capsule()
                            .fill(Studio.Palette.accent)
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
