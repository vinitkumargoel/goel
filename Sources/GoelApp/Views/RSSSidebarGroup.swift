import SwiftUI
import GoelCore

/// "Feeds" in the sidebar: one row that opens the RSS reader, with the total unread count.
struct RSSSidebarGroup: View {
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject private var model = RSSReaderModel.shared

    private var unread: Int { vm.settings.rssFeeds.reduce(0) { $0 + model.unreadCount($1.id) } }

    var body: some View {
        Text(L10n.t("Feeds").uppercased())
            .scaledFont(size: Theme.TextSize.caption, weight: .bold)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.t("Feeds"))
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
        Button {
            vm.closeServerBrowser()
            model.open()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "dot.radiowaves.up.forward").scaledFont(size: Theme.TextSize.body)
                    .frame(width: 16)
                Text(L10n.t("RSS")).scaledFont(size: Theme.TextSize.body)
                Spacer(minLength: 4)
                if unread > 0 {
                    Text(verbatim: "\(unread)")
                        .scaledFont(size: Theme.TextSize.caption, monospacedDigit: true)
                        .foregroundStyle(model.isOpen ? Theme.onIndigo : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(model.isOpen ? Theme.indigo : Color.clear))
            .foregroundStyle(model.isOpen ? Theme.onIndigo : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("RSS feeds"))
        .accessibilityValue(L10n.t("%d unread", unread))
        .accessibilityAddTraits(model.isOpen ? [.isButton, .isSelected] : .isButton)
    }
}
