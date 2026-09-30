import SwiftUI
import GoelCore

/// The detail panel with nothing selected: what the whole queue is doing. It fills space that
/// was an empty "No selection" state with the numbers people otherwise open three places for.
struct QueueOverviewPanel: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    /// Wide in the bottom dock, where the tiles sit beside the numbers instead of under them.
    var horizontal = false

    /// Read on a timer, not per frame: it is a filesystem call.
    @State private var diskFree: Int64?

    var body: some View {
        let overview = QueueOverview(tasks: vm.tasks) { telemetry.displaySpeed(for: $0) }
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("Queue overview"))
                    .scaledFont(size: Theme.TextSize.title, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                PanelDockToggle()
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            ScrollView {
                if horizontal {
                    HStack(alignment: .top, spacing: Theme.Space.xl) {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            speeds(overview)
                            TaskSpeedGraphGlobal()
                        }
                        .frame(maxWidth: 320)
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            tiles(overview)
                            facts(overview)
                        }
                        .frame(maxWidth: 420)
                    }
                    .padding(.horizontal, Theme.Space.l)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        speeds(overview)
                        TaskSpeedGraphGlobal()
                        tiles(overview)
                        facts(overview)
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.l)
                }
            }
        }
        .task(id: vm.settings.defaultSaveDirectory) {
            while !Task.isCancelled {
                let folder = vm.settings.defaultSaveDirectory
                diskFree = await Task.detached(priority: .utility) {
                    DiskSpaceCheck.availableCapacity(forFolder: folder)
                }.value
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func speeds(_ overview: QueueOverview) -> some View {
        HStack(spacing: Theme.Space.s) {
            speedTile(L10n.t("Down"), speed: overview.speed.down, direction: .down)
            speedTile(L10n.t("Up"), speed: overview.speed.up, direction: .up)
        }
    }

    private func speedTile(_ label: String, speed: Double, direction: SpeedDirection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            DetailSpeedStat(symbol: direction.symbol, speed: speed, color: direction.tint, size: 15)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fillRest, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    /// Each tile applies its sidebar filter, so the overview is also a way to get to the rows.
    private func tiles(_ overview: QueueOverview) -> some View {
        HStack(spacing: Theme.Space.xs) {
            tile(overview.active, L10n.t("active"), filter: .active)
            tile(overview.queued, L10n.t("queued"), filter: .queued)
            tile(overview.done, L10n.t("done"), filter: .completed)
            tile(overview.failed, L10n.t("failed"), filter: .failed,
                 tint: overview.failed > 0 ? Theme.red : nil)
        }
    }

    private func tile(_ count: Int, _ label: String, filter: SidebarFilter, tint: Color? = nil) -> some View {
        Button {
            vm.closeServerBrowser()
            vm.filter = filter
        } label: {
            VStack(spacing: 1) {
                Text("\(count)")
                    .scaledFont(size: Theme.TextSize.sheet, weight: .bold, monospacedDigit: true)
                Text(label)
                    .scaledFont(size: Theme.TextSize.caption)
            }
            .foregroundStyle(tint ?? Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.fillRest, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(tint?.opacity(0.5) ?? Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Show %@", filter.accessibilityName))
        .a11yButton(L10n.t("%1$d %2$@", count, label), hint: L10n.t("Activate to filter the list."))
    }

    private func facts(_ overview: QueueOverview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            KVRow(key: L10n.t("Remaining"), value: remainingText(overview))
            KVRow(key: L10n.t("Disk free"), value: diskFree.map(\.byteString) ?? "—")
            KVRow(key: L10n.t("Speed limit"),
                  value: SpeedProfileText.pill(limitEnabled: vm.settings.speedLimitEnabled,
                                               profile: vm.settings.selectedProfile))
            KVRow(key: L10n.t("Queue profile"), value: vm.settings.selectedProfile.name)
        }
    }

    private func remainingText(_ overview: QueueOverview) -> String {
        guard overview.remainingBytes > 0 || overview.hasUnknownSize else { return L10n.t("Nothing left") }
        let bytes = overview.remainingBytes.byteString
        if let done = overview.doneText() { return L10n.t("%1$@ · %2$@", bytes, done) }
        return bytes
    }
}

/// The last minute of the combined ↓ speed at the panel's width.
private struct TaskSpeedGraphGlobal: View {
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        let history = telemetry.recentGlobalHistory(60)
        SparklineView(values: history.map(\.down), tint: Theme.green)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("Download speed history"))
            .accessibilityValue(L10n.t("peak %@ in the last minute", A11y.speed(history.map(\.down).max() ?? 0)))
    }
}
