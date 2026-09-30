import SwiftUI
import GoelCore

/// The detail panel while several rows are selected: what the selection adds up to, and the
/// bulk commands the list's context menu offers — calling the same view-model methods.
struct MultiSelectionPanel: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        let summary = SelectionAggregate(tasks: vm.selectedTasks) { telemetry.displaySpeed(for: $0) }
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                PanelDockToggle()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ScrollView {
                VStack(spacing: 16) {
                    tileStack(summary.preview)
                        .padding(.top, 4)
                    VStack(spacing: 4) {
                        Text(summary.title)
                            .scaledFont(size: Theme.TextSize.title, weight: .semibold)
                            .accessibilityAddTraits(.isHeader)
                        if !summary.subtitle.isEmpty {
                            Text(summary.subtitle)
                                .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)

                    ZStack {
                        ProgressRing(fraction: summary.fraction,
                                     tint: summary.failedCount == summary.count ? Theme.red : Theme.accent)
                            .frame(width: 104, height: 104)
                        Text("\(Int((summary.fraction * 100).rounded()))%")
                            .scaledFont(size: 22, weight: .bold, monospacedDigit: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityLabel(L10n.t("Combined progress"))
                    .accessibilityValue(A11y.percent(summary.fraction))

                    HStack(spacing: 22) {
                        DetailSpeedStat(symbol: "arrow.down", speed: summary.speed.down, color: Theme.green, size: 13)
                        DetailSpeedStat(symbol: "arrow.up", speed: summary.speed.up, color: Theme.teal, size: 13)
                    }

                    actions(summary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
        }
    }

    /// Up to three file tiles fanned out, the first on top.
    private func tileStack(_ tasks: [DownloadTask]) -> some View {
        ZStack {
            ForEach(Array(tasks.enumerated().reversed()), id: \.element.id) { index, task in
                FileTypeIcon(type: task.fileType, size: 48)
                    .rotationEffect(.degrees(Double(index) * 8))
                    .offset(x: CGFloat(index) * 14, y: CGFloat(index) * -3)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
        }
        .frame(width: 96, height: 64)
        .a11yDecorative()
    }

    private func actions(_ summary: SelectionAggregate) -> some View {
        let count = summary.count
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                         spacing: 8) {
            action(L10n.t("Resume"), "play.fill", spoken: L10n.t("Resume %d Selected", count),
                   enabled: summary.canResume, prominent: summary.canResume) { vm.resumeSelected() }
            action(L10n.t("Pause"), "pause.fill", spoken: L10n.t("Pause %d Selected", count),
                   enabled: summary.canPause) { vm.pauseSelected() }
            action(L10n.t("Retry"), "arrow.clockwise", spoken: L10n.t("Retry %d Selected", count),
                   enabled: summary.canRetry) { vm.retrySelected() }
            action(L10n.t("Move to…"), "folder", spoken: L10n.t("Move %d selected downloads", count),
                   enabled: summary.canMove) {
                if let url = FilePicker.chooseDirectory(prompt: L10n.t("Move Here"),
                                                        message: L10n.t("Choose a folder for %d downloads.", count)) {
                    vm.moveSelected(to: url.path)
                }
            }
            action(L10n.t("Tag…"), "tag", spoken: L10n.t("Add tags to %d downloads", count)) {
                vm.promptForTagsOnSelection()
            }
            action(L10n.t("Remove"), "trash", spoken: L10n.t("Remove %d from List", count),
                   tint: Theme.red) { vm.removeSelected(deleteData: false) }
        }
    }

    private func action(_ title: String, _ symbol: String, spoken: String, enabled: Bool = true,
                        prominent: Bool = false, tint: Color = Color.primary,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
        }
        .buttonStyle(TintedPillButtonStyle(tint: prominent ? Theme.accent : tint,
                                           prominent: prominent, fillWidth: true))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .a11yButton(spoken)
    }
}
