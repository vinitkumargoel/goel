import SwiftUI
import GoelCore

/// "Custom… ↓ ↑": caps the active profile and turns the limit on, without opening Settings.
struct SpeedCapPopover: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var down = ""
    @State private var up = ""
    @FocusState private var focused: Field?

    private enum Field { case down, up }

    private var parsedDown: Int64? { SpeedCapInput.parse(down) }
    private var parsedUp: Int64? { SpeedCapInput.parse(up) }
    private var canApply: Bool { parsedDown != nil && parsedUp != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Studio.Space.sm) {
                Text(L10n.t("Custom speed limit"))
                    .studioFont(.title3)
                    .foregroundStyle(Studio.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                WindowsLabeledField(label: L10n.t("Download limit")) {
                    field(text: $down, parsed: parsedDown, field: .down, label: L10n.t("Download limit"))
                }
                WindowsLabeledField(label: L10n.t("Upload limit")) {
                    field(text: $up, parsed: parsedUp, field: .up, label: L10n.t("Upload limit"))
                }
                Text(L10n.t("MB/s — or add k, e.g. 500k. Blank means unlimited. Applies to the %@ profile.",
                            vm.settings.selectedProfileName))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, Studio.Space.ml)
            HStack(spacing: Studio.Space.s) {
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Apply")) { apply() }
                    .buttonStyle(.studio(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, Studio.Space.m)
            .background(Studio.Palette.well)
            .overlay(alignment: .top) { StudioDivider() }
        }
        .frame(width: 300)
        .background(Studio.Palette.cardRaised)
        .onAppear {
            down = SpeedCapInput.format(vm.settings.selectedProfile.maxDownloadBytesPerSec)
            up = SpeedCapInput.format(vm.settings.selectedProfile.maxUploadBytesPerSec)
            focused = .down
        }
    }

    private func field(text: Binding<String>, parsed: Int64?, field: Field, label: String) -> some View {
        HStack(spacing: Studio.Space.s) {
            Image(systemName: field == .down ? "arrow.down" : "arrow.up")
                .studioFont(.ui, size: 11, weight: 700)
                .foregroundStyle(field == .down ? Studio.Palette.accent : Studio.Palette.upload)
                .accessibilityHidden(true)
            TextField("∞", text: text)
                .textFieldStyle(.plain)
                .studioFont(.monoBody)
                .focused($focused, equals: field)
                .onSubmit(apply)
                .accessibilityLabel(label)
                .accessibilityValue(readout(parsed))
            Text(readout(parsed))
                .studioFont(.caption)
                .foregroundStyle(parsed == nil ? Studio.Palette.bad : Studio.Palette.ink3)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Studio.Space.m)
        .frame(minHeight: 36)
        .modifier(StudioFieldChrome(isFocused: focused == field))
    }

    /// What the field will apply: "500 KB/s", "Unlimited", or that it can't be read.
    private func readout(_ parsed: Int64?) -> String {
        guard let parsed else { return L10n.t("Not a speed") }
        return parsed > 0 ? Double(parsed).speedString : L10n.t("Unlimited")
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
            guard let index = settings.profiles.firstIndex(where: { $0.name == settings.selectedProfileName })
            else { return }
            settings.profiles[index].maxDownloadBytesPerSec = down
            settings.profiles[index].maxUploadBytesPerSec = up
            settings.speedLimitEnabled = true
        }
        let downText = down > 0 ? Double(down).speedString : "∞"
        let upText = up > 0 ? Double(up).speedString : "∞"
        toastSuccess(L10n.t("Speed limit on · ↓ %1$@ ↑ %2$@", downText, upText))
    }
}
