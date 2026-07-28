import SwiftUI
import GoelCore

struct PaneScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).scaledFont(size: 15, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).scaledFont(size: 12).foregroundStyle(.secondary).padding(.bottom, 16)
            content
        }
    }
}

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .scaledFont(size: 10.5, weight: .bold)
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SetRow<Control: View>: View {
    let name: String
    let desc: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).scaledFont(size: 13)
                if !desc.isEmpty {
                    Text(desc).scaledFont(size: 11).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            control
        }
        .environment(\.settingRowName, name)
        .padding(.vertical, 10)
        Divider()
    }
}

private struct SettingRowNameKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    var settingRowName: String {
        get { self[SettingRowNameKey.self] }
        set { self[SettingRowNameKey.self] = newValue }
    }
}

struct SettingSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.settingRowName) private var rowName
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
            .accessibilityLabel(rowName)
    }
}

struct SettingText: View {
    @Binding var text: String
    var width: CGFloat = 80
    @Environment(\.settingRowName) private var rowName
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: width)
            .accessibilityLabel(rowName)
    }
}

/// Ungrouped: `.number` would render port 8899 as "8,899", which won't type back.
struct SettingInt: View {
    @Binding var value: Int
    var width: CGFloat = 80
    @Environment(\.settingRowName) private var rowName
    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).frame(width: width)
            .accessibilityLabel(rowName)
    }
}

/// Ungrouped for the same reason as `SettingInt`.
struct SettingDouble: View {
    @Binding var value: Double
    var width: CGFloat = 80
    @Environment(\.settingRowName) private var rowName
    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).frame(width: width)
            .accessibilityLabel(rowName)
    }
}

extension View {

    /// Only `isLocked` keys disable a control; a managed *default* must stay editable.
    @ViewBuilder
    func managed(_ key: ManagedPolicy.Key, _ policy: ManagedPolicy) -> some View {
        if policy.isLocked(key) {
            self.disabled(true)
                .help(AppViewModel.managedFootnote)
                .accessibilityHint(AppViewModel.managedFootnote)
        } else {
            self
        }
    }
}

struct ManagedPolicyNotice: View {

    let policy: ManagedPolicy

    let keys: [ManagedPolicy.Key]

    var body: some View {
        if keys.contains(where: policy.isLocked) {
            Label(L10n.t("Some settings here are managed by your organisation and can’t be changed."),
                  systemImage: "lock.fill")
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
