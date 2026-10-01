import SwiftUI
import GoelCore

/// "Custom… ↓ ↑": caps the active profile and turns the limit on, without opening Settings.
struct SpeedCapPopover: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var down = ""
    @State private var up = ""

    private var parsedDown: Int64? { SpeedCapInput.parse(down) }
    private var parsedUp: Int64? { SpeedCapInput.parse(up) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("Custom speed limit")).scaledFont(size: Theme.TextSize.body, weight: .semibold)
            HStack(spacing: 8) {
                field("↓", text: $down, label: L10n.t("Download limit"))
                field("↑", text: $up, label: L10n.t("Upload limit"))
            }
            Text(L10n.t("MB/s — or add k, e.g. 500k. Blank means unlimited. Applies to the %@ profile.",
                        vm.settings.selectedProfileName))
                .scaledFont(size: Theme.TextSize.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Apply")) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedDown == nil || parsedUp == nil)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            down = SpeedCapInput.format(vm.settings.selectedProfile.maxDownloadBytesPerSec)
            up = SpeedCapInput.format(vm.settings.selectedProfile.maxUploadBytesPerSec)
        }
    }

    private func field(_ arrow: String, text: Binding<String>, label: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: arrow).foregroundStyle(.secondary).a11yDecorative()
            TextField("∞", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .onSubmit(apply)
                .accessibilityLabel(label)
        }
    }

    private func apply() {
        guard let d = parsedDown, let u = parsedUp else { return }
        vm.applyCustomSpeedCap(down: d, up: u)
        dismiss()
    }
}

extension AppViewModel {
    /// Writes the caps into the active profile and switches the global limit on.
    func applyCustomSpeedCap(down: Int64, up: Int64) {
        guard !managedPolicy.isLocked(.speedLimitEnabled) else {
            toastWarning(AppViewModel.managedFootnote)
            return
        }
        update { settings in
            guard let index = settings.profiles.firstIndex(where: { $0.name == settings.selectedProfileName }) else { return }
            settings.profiles[index].maxDownloadBytesPerSec = down
            settings.profiles[index].maxUploadBytesPerSec = up
            settings.speedLimitEnabled = true
        }
        let downText = down > 0 ? Double(down).speedString : "∞"
        let upText = up > 0 ? Double(up).speedString : "∞"
        toastSuccess(L10n.t("Speed limit on · ↓ %1$@ ↑ %2$@", downText, upText))
    }
}
