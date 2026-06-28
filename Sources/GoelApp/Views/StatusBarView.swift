import SwiftUI
import GoelCore

/// The bottom status bar: the speed-limit "snail" toggle, aggregate ↓/↑ totals,
/// and the Low / Medium / High profile picker.
struct StatusBarView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: 14) {
            snail
            stat(symbol: "arrow.down", value: vm.totalDownloadSpeed.speedString, color: Theme.green)
            stat(symbol: "arrow.up", value: vm.totalUploadSpeed.speedString, color: Theme.teal)
            Spacer()
            Text("Profile").font(.system(size: 11)).foregroundStyle(.tertiary)
            profilePicker
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.bar)
    }

    private var snail: some View {
        Button(action: vm.toggleSnail) {
            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill").font(.system(size: 12))
                Text(vm.settings.speedLimitEnabled ? vm.settings.selectedProfileName : "Unlimited")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(vm.settings.speedLimitEnabled ? Theme.orange.opacity(0.18) : Color.primary.opacity(0.08))
            )
            .foregroundStyle(vm.settings.speedLimitEnabled ? Theme.orange : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle global speed limit")
    }

    private func stat(symbol: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
    }

    private var profilePicker: some View {
        HStack(spacing: 2) {
            ForEach(vm.settings.profiles) { profile in
                let selected = profile.name == vm.settings.selectedProfileName
                Button {
                    vm.setProfile(profile.name)
                } label: {
                    Text(profile.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Theme.accent : Color.clear)
                        )
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}
