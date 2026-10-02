import SwiftUI
import GoelCore

// Small helpers shared by the settings panes (and the onboarding): `setting(vm, \.keyPath)`,
// `SettingSwitch` and `\.settingRowName`, which lets a control in a row name itself.

/// A binding to one `AppSettings` field that writes through `vm.update`.
@MainActor
func setting<T>(_ vm: AppViewModel, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { vm.settings[keyPath: keyPath] },
        set: { newValue in vm.update { $0[keyPath: keyPath] = newValue } }
    )
}

/// The Studio switch for a setting row; VoiceOver hears the row's title.
struct SettingSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.settingRowName) private var rowName

    var body: some View {
        Toggle(isOn: $isOn) { EmptyView() }
            .labelsHidden()
            .toggleStyle(.studioSwitch)
            .accessibilityLabel(rowName)
    }
}

private struct SettingRowNameKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    /// The title of the setting row a control sits in, so the control can name itself.
    var settingRowName: String {
        get { self[SettingRowNameKey.self] }
        set { self[SettingRowNameKey.self] = newValue }
    }
}
