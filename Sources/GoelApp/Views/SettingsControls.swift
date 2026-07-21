import SwiftUI

// Reusable building blocks for the Preferences panes. Split out of
// `SettingsView.swift` so each pane reads as a flat list of `SetRow`s.

// MARK: - Building blocks

struct PaneScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 16)
            content
        }
    }
}

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

struct SetRow<Control: View>: View {
    let name: String
    let desc: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13))
                if !desc.isEmpty {
                    Text(desc).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
            control
        }
        .padding(.vertical, 10)
        Divider()
    }
}

// MARK: - Bound controls

/// A switch backed by a real settings `Binding`, so its initial state reflects
/// the persisted value and toggling commits through ``AppViewModel/update(_:)``.
struct SettingSwitch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch) }
}

/// A free-text field bound to a settings string.
struct SettingText: View {
    @Binding var text: String
    var width: CGFloat = 80
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: width)
    }
}

/// A numeric field bound to a settings integer.
struct SettingInt: View {
    @Binding var value: Int
    var width: CGFloat = 80
    var body: some View {
        TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: width)
    }
}

/// A numeric field bound to a settings double (timeouts, intervals, speeds, ratio).
struct SettingDouble: View {
    @Binding var value: Double
    var width: CGFloat = 80
    var body: some View {
        TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: width)
    }
}
