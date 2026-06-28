import SwiftUI
import GoelCore

/// The left sidebar: Library / Status / Type groups with live counts, mirroring
/// the mockup's `.sidebar`.
struct SidebarView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                group("Library") {
                    item("All files", "tray.full", .all)
                }
                group("Status") {
                    item("Active", "arrow.down.circle", .active)
                    item("Paused", "pause.circle", .paused)
                    item("Completed", "checkmark.circle", .completed)
                    item("Seeding", "arrow.up.circle", .seeding)
                }
                group("Type") {
                    item("Video", "film", .type(.video))
                    item("Disc images", "opticaldisc", .type(.iso))
                    item("Archives", "doc.zipper", .type(.archive))
                    item("Apps", "app.badge", .type(.app))
                }
            }
            .padding(10)
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
        content()
    }

    private func item(_ label: String, _ symbol: String, _ filter: SidebarFilter) -> some View {
        let selected = vm.filter == filter
        return Button {
            vm.filter = filter
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(vm.count(for: filter))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.accent : Color.clear)
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
